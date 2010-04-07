#include <cuda.h>
#include <fcntl.h>
#include <stdio.h>
#include <errno.h>
#include <stdlib.h>
#include <stdint.h>
#include <unistd.h>
#include <sys/time.h>
#include <sys/mman.h>
#include <driver_types.h>
#include <cuda_runtime_api.h>

// CUDA must already have been initialized before calling cudaid().
#define CUDASTRLEN 80
static int
id_cuda(int dev,unsigned *mem,unsigned *tmem){
	struct cudaDeviceProp dprop;
	int major,minor,attr,cerr;
	void *str = NULL;
	CUcontext ctx;
	CUdevice c;

	if((cerr = cuDeviceGet(&c,dev)) != CUDA_SUCCESS){
		return cerr;
	}
	if((cerr = cudaGetDeviceProperties(&dprop,dev)) != CUDA_SUCCESS){
		return cerr;
	}
	cerr = cuDeviceGetAttribute(&attr,CU_DEVICE_ATTRIBUTE_WARP_SIZE,c);
	if(cerr != CUDA_SUCCESS || attr <= 0){
		return cerr;
	}
	cerr = cuDeviceGetAttribute(&attr,CU_DEVICE_ATTRIBUTE_MULTIPROCESSOR_COUNT,c);
	if(cerr != CUDA_SUCCESS || attr <= 0){
		return cerr;
	}
	if((cerr = cuDeviceComputeCapability(&major,&minor,c)) != CUDA_SUCCESS){
		return cerr;
	}
	if((str = malloc(CUDASTRLEN)) == NULL){
		return -1;
	}
	if((cerr = cuDeviceGetName((char *)str,CUDASTRLEN,c)) != CUDA_SUCCESS){
		goto err;
	}
	if((cerr = cuCtxCreate(&ctx,0,c)) != CUDA_SUCCESS){
		goto err;
	}
	if((cerr = cuMemGetInfo(mem,tmem)) != CUDA_SUCCESS){
		cuCtxDetach(ctx);
		goto err;
	}
	if(printf("%d.%d %s %s %u/%uMB free %s\n",
		major,minor,
		dprop.integrated ? "Integrated" : "Standalone",(char *)str,
		*mem / (1024 * 1024) + !!(*mem / (1024 * 1024)),
		*tmem / (1024 * 1024) + !!(*tmem / (1024 * 1024)),
		dprop.computeMode == CU_COMPUTEMODE_EXCLUSIVE ? "(exclusive)" :
		dprop.computeMode == CU_COMPUTEMODE_PROHIBITED ? "(prohibited)" :
		dprop.computeMode == CU_COMPUTEMODE_DEFAULT ? "" :
		"(unknown compute mode)") < 0){
		cuCtxDetach(ctx);
		cerr = -1;
		goto err;
	}
	if((cerr = cuCtxDetach(ctx)) != CUDA_SUCCESS){
		goto err;
	}
	free(str);
	return CUDA_SUCCESS;

err:	// cerr ought already be set!
	free(str);
	return cerr;
}

#define CUDAMAJMIN(v) v / 1000, v % 1000

static int
init_cuda(int *count){
	int attr,cerr;

	if((cerr = cuInit(0)) != CUDA_SUCCESS){
		return cerr;
	}
	if((cerr = cuDriverGetVersion(&attr)) != CUDA_SUCCESS){
		return cerr;
	}
	printf("Compiled against CUDA version %d.%d. Linked against CUDA version %d.%d.\n",
			CUDAMAJMIN(CUDA_VERSION),CUDAMAJMIN(attr));
	if(CUDA_VERSION > attr){
		fprintf(stderr,"Compiled against a newer version of CUDA than that installed, exiting.\n");
		return -1;
	}
	if((cerr = cuDeviceGetCount(count)) != CUDA_SUCCESS){
		return cerr;
	}
	if(*count <= 0){
		fprintf(stderr,"No CUDA devices found, exiting.\n");
		return -1;
	}
	printf("CUDA device count: %d\n",*count);
	return CUDA_SUCCESS;
}

#define ADDRESS_BITS 32u // FIXME 40 on compute capability 2.0!
#define CONSTWIN 0x10000u
#define BLOCK_SIZE 512 // FIXME bigger would likely be better

__device__ __constant__ unsigned constptr[1];

__global__ void memkernel(uintptr_t aptr,unsigned b){
	__shared__ unsigned psum[BLOCK_SIZE];
	unsigned *ptr,bp;

	psum[threadIdx.x] = 0;
	for(ptr = constptr ; ptr < (unsigned *)CONSTWIN ; ptr += BLOCK_SIZE){
		psum[threadIdx.x] += ptr[threadIdx.x];
	}
	// Accesses below 64k result in immediate termination. I believe this
	// the result of constant memory (.const state space; see 5.1.3 of the
	// PTX 2.0 Reference) being mapped there, but global references
	// (.global state space; see section 5.1.4) being generated by nvcc.
	for(ptr = (unsigned *)CONSTWIN ; ptr < (unsigned *)aptr ; ptr += BLOCK_SIZE){
		psum[threadIdx.x] += ptr[threadIdx.x];
	}
	// We've checksummed from 64k through the provided pointer. Now,
	// checksum the allocated area -- |b| words, rounded up to the nearest
	// multiple of the block size.
	for(bp = 0 ; bp < b ; bp += BLOCK_SIZE){
		psum[threadIdx.x] += *(unsigned *)
			((uintmax_t)(aptr + 4 * bp + threadIdx.x)
			 % (1lu << ADDRESS_BITS));
	}
}

// Takes in start and end of memory area to be scanned, and fd. Returns the
// number of 32-bit words in this region, or 0 on error. mstart and mend must
// be 4-byte aligned, and mstart must be less than mend. Requires sufficient
// virtual memory to allocate the bitmap, and sufficient disk space for the
// backing file (FIXME actually, we currently use a hole, so not quite...).
static uintmax_t
create_bitmap(uintptr_t mstart,uintptr_t mend,int fd,void **bmap){
#define UNIT 4
	int mflags;
	size_t s;

	if(mstart % UNIT || mend % UNIT || mstart >= mend || fd < 0){
		errno = EINVAL;
		return 0;
	}
	mflags = MAP_SHARED;
#ifdef MAP_HUGETLB
	mflags |= MAP_HUGETLB;
#endif
	s = (mend - mstart) / UNIT / CHAR_BIT;
	*bmap = mmap(NULL,s,PROT_READ|PROT_WRITE,mflags,fd,0);
	if(*bmap == MAP_FAILED){
		return 0;
	}
	if(ftruncate(fd,s)){
		munmap(*bmap,s);
		return 0;
	}
	return s * CHAR_BIT;
#undef UNIT
}

static int
dump_cuda(uintmax_t mem,uintmax_t tmem,int fd){
	struct timeval time0,time1,timer;
	dim3 dblock(BLOCK_SIZE,1,1);
	uintmax_t words,usec;
	dim3 dgrid(1,1,1);
	void *ptr,*map;
	int unit = 'M';
	uintmax_t s;
	float bw;

	s = mem - 0x8000000;
	if(cudaMalloc(&ptr,s)){
		cudaError_t err;

		err = cudaGetLastError();
		fprintf(stderr,"  Error allocating %jub (%s?)\n",
				s,cudaGetErrorString(err));
		return -1;
	}
	printf("  Allocated %ju of %ju MB at %p\n",
			s / (1024 * 1024) + !!(s % (1024 * 1024)),
			tmem / (1024 * 1024) + !!(tmem % (1024 * 1024)),ptr);
	// FIXME need to set fd, free up bitmap (especially on error paths!)
	if((words = create_bitmap(0,(uintptr_t)((char *)ptr + s),fd,&map)) == 0){
		fprintf(stderr,"  Error creating bitmap (%s?)\n",
				strerror(errno));
		return -1;
	}
	printf("  memkernel {%u x %u} x {%u x %u x %u} (%p, %ju (%jub))\n",
			dgrid.x,dgrid.y,dblock.x,dblock.y,dblock.z,ptr,words,s);
	gettimeofday(&time0,NULL);
	memkernel<<<dgrid,dblock>>>((uintptr_t)ptr,words - (uintptr_t)ptr / 4);
	if(cudaThreadSynchronize()){
		cudaError_t err;

		err = cudaGetLastError();
		fprintf(stderr,"  Error running kernel (%s?)\n",
				cudaGetErrorString(err));
		return -1;
	}
	gettimeofday(&time1,NULL);
	timersub(&time1,&time0,&timer);
	usec = (timer.tv_sec * 1000000 + timer.tv_usec);
	bw = (float)s / usec;
	if(bw > 1000.0f){
		bw /= 1000.0f;
		unit = 'G';
	}
	printf("  elapsed time: %ju.%jus (%.3f %cB/s)\n",
			usec / 1000000,usec % 1000000,bw,unit);
	if(cudaFree(ptr) || cudaThreadSynchronize()){
		cudaError_t err;

		err = cudaGetLastError();
		fprintf(stderr,"  Error dumping CUDA memory (%s?)\n",
				cudaGetErrorString(err));
		return -1;
	}
	return 0;
}

int main(void){
	int z,count;

	if(init_cuda(&count)){
		cudaError_t err;

		err = cudaGetLastError();
		fprintf(stderr,"Error initializing CUDA (%s?)\n",
				cudaGetErrorString(err));
		return EXIT_FAILURE;
	}
	for(z = 0 ; z < count ; ++z){
		unsigned mem,tmem;
		int fd;

		printf(" %03d ",z);
		if(id_cuda(z,&mem,&tmem)){
			cudaError_t err;

			err = cudaGetLastError();
			fprintf(stderr,"\nError probing CUDA device %d (%s?)\n",
					z,cudaGetErrorString(err));
			return EXIT_FAILURE;
		}
		if((fd = open("cudamemory",O_RDWR|O_CREAT,S_IRUSR|S_IWUSR|S_IRGRP|S_IWGRP|S_IROTH)) < 0){
			fprintf(stderr,"\nError creating bitmap (%s?)\n",strerror(errno));
			return EXIT_FAILURE;
		}
		if(dump_cuda(mem,tmem,fd)){
			close(fd);
			return EXIT_FAILURE;
		}
		if(close(fd)){
			fprintf(stderr,"\nError closing bitmap (%s?)\n",strerror(errno));
			return EXIT_FAILURE;
		}
	}
	return EXIT_SUCCESS;
}

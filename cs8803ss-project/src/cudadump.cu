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
id_cuda(int dev,unsigned *mem,unsigned *tmem,CUcontext *ctx){
	struct cudaDeviceProp dprop;
	int major,minor,attr,cerr;
	void *str = NULL;
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
	if((cerr = cuCtxCreate(ctx,0,c)) != CUDA_SUCCESS){
		goto err;
	}
	if((cerr = cuMemGetInfo(mem,tmem)) != CUDA_SUCCESS){
		cuCtxDetach(*ctx);
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
		cuCtxDetach(*ctx);
		cerr = -1;
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
#define CONSTWIN ((unsigned *)0x10000u)
#define BLOCK_SIZE 512 // FIXME bigger would likely be better

__device__ __constant__ unsigned constptr[1];

__global__ void constkernel(const unsigned *constmax){
	__shared__ unsigned psum[BLOCK_SIZE];
	unsigned *ptr;

	psum[threadIdx.x] = 0;
	// Accesses below 64k result in immediate termination, due to use of
	// the .global state space (2.0 provides unified addressing, which can
	// overcome this). That area's reserved for constant memory (.const
	// state space; see 5.1.3 of the PTX 2.0 Reference), from what I see.
	for(ptr = constptr ; ptr < constmax ; ptr += BLOCK_SIZE){
		psum[threadIdx.x] += ptr[threadIdx.x];
	}
}

__global__ void
memkernel(uintptr_t aptr,const uintptr_t bptr,const unsigned unit){
	__shared__ unsigned psum[BLOCK_SIZE];

	psum[threadIdx.x] = 0;
	while(aptr + threadIdx.x * unit < bptr){
		psum[threadIdx.x] += *(unsigned *)
			((uintmax_t)(aptr + unit * threadIdx.x)
				% (1lu << ADDRESS_BITS));
		aptr += BLOCK_SIZE * unit;
	}
}

// Takes in start and end of memory area to be scanned, and fd. Returns the
// number of |unit|-byte words in this region, or 0 on error. mstart and mend
// must be |unit|-byte aligned, and mstart must be less than mend. Requires
// sufficient virtual memory to allocate the bitmap, and sufficient disk space
// for the backing file (FIXME we currently use a hole, so not quite...).
static uintmax_t
create_bitmap(uintptr_t mstart,uintptr_t mend,int fd,void **bmap,unsigned unit){
	int mflags;
	size_t s;

	if(!unit || mstart % unit || mend % unit || mstart >= mend || fd < 0){
		errno = EINVAL;
		return 0;
	}
	mflags = MAP_SHARED;
#ifdef MAP_HUGETLB
	mflags |= MAP_HUGETLB;
#endif
	s = (mend - mstart) / unit / CHAR_BIT;
	*bmap = mmap(NULL,s,PROT_READ|PROT_WRITE,mflags,fd,0);
	if(*bmap == MAP_FAILED){
		return 0;
	}
	if(ftruncate(fd,s)){
		munmap(*bmap,s);
		return 0;
	}
	return s * CHAR_BIT;
}

static uintmax_t
cuda_alloc_max(uintmax_t tmax,CUdeviceptr *ptr,unsigned unit){
	uintmax_t min = 0,s;

	printf("  Determining max allocation...");
	while( (s = ((tmax + min) / 2) & (~(uintmax_t)0u << 2u)) ){
		fflush(stdout);

		if(cuMemAlloc(ptr,s)){
			if((tmax = s) <= min + unit){
				tmax = min;
			}
		}else if(s != tmax && s != min){
			printf("%jub...",s);
			// Arbitrary canary constant
			cuMemsetD32(*ptr,0x42069420,s / unit);
			if(cuMemFree(*ptr)){
				cudaError_t err;

				err = cudaGetLastError();
				fprintf(stderr,"  Couldn't free %jub (%s?)\n",
						s,cudaGetErrorString(err));
				return 0;
			}
			min = s;
		}else{
			printf("%jub!\n",s);
			return s;
		}
	}
	fprintf(stderr,"  All allocations failed.\n");
	return 0;
}

static int
divide_address_space(uintmax_t off,uintmax_t s,unsigned unit){
	struct timeval time0,time1,timer;
	dim3 dblock(BLOCK_SIZE,1,1);
	dim3 dgrid(1,1,1);
	uintmax_t usec;
	int punit = 'M';
	float bw;

	if(s < unit){
		fprintf(stderr,"  Granularity violation: %ju < %u\n",s,unit);
		return -1;
	}
	printf("  memkernel {%u x %u} x {%u x %u x %u} (%jx, %jx (%jub), %u)\n",
		dgrid.x,dgrid.y,dblock.x,dblock.y,dblock.z,off,off + s,s,unit);
	gettimeofday(&time0,NULL);
	memkernel<<<dgrid,dblock>>>(off,off + s,unit);
	if(cudaThreadSynchronize()){
		cudaError_t err;

		err = cudaGetLastError();
		fprintf(stderr,"  Error running kernel (%s?)\n",
				cudaGetErrorString(err));
		if(divide_address_space(off,s / 2,unit)){
			return -1;
		}
		if(divide_address_space(off + s / 2,s / 2,unit)){
			return -1;
		}
		return 0;
	}
	gettimeofday(&time1,NULL);
	timersub(&time1,&time0,&timer);
	usec = (timer.tv_sec * 1000000 + timer.tv_usec);
	bw = (float)s / usec;
	if(bw > 1000.0f){
		bw /= 1000.0f;
		punit = 'G';
	}
	printf("  elapsed time: %ju.%jus (%.3f %cB/s)\n",
			usec / 1000000,usec % 1000000,bw,punit);
	return 0;
}

static int
check_const_ram(const unsigned *max){
	dim3 dblock(BLOCK_SIZE,1,1);
	dim3 dgrid(1,1,1);

	printf("  Verifying %jub constant memory...",(uintmax_t)max);
	fflush(stdout);
	constkernel<<<dblock,dgrid>>>(max);
	if(cuCtxSynchronize()){
		cudaError_t err;

		err = cudaGetLastError();
		fprintf(stderr,"\n  Error verifying constant CUDA memory (%s?)\n",
				cudaGetErrorString(err));
		return -1;
	}
	printf("good.\n");
	return 0;
}

static int
dump_cuda(uintmax_t tmem,int fd,unsigned unit,unsigned gran){
	uintmax_t words;
	CUdeviceptr ptr;
	uintmax_t s;
	void *map;

	if((s = cuda_alloc_max(tmem,&ptr,unit)) == 0){
		return -1;
	}
	printf("  Allocated %ju of %ju MB at %p\n",
			s / (1024 * 1024) + !!(s % (1024 * 1024)),
			tmem / (1024 * 1024) + !!(tmem % (1024 * 1024)),ptr);
	if(check_const_ram(CONSTWIN)){
		return -1;
	}
	// FIXME need to set fd, free up bitmap (especially on error paths!)
	if((words = create_bitmap(0,(uintptr_t)((char *)ptr + s),fd,&map,unit)) == 0){
		fprintf(stderr,"  Error creating bitmap (%s?)\n",
				strerror(errno));
		return -1;
	}
	if(divide_address_space((uintmax_t)ptr,s,unit)){
		return -1;
	}
	if(cuMemFree(ptr) || cuCtxSynchronize()){
		cudaError_t err;

		err = cudaGetLastError();
		fprintf(stderr,"  Error dumping CUDA memory (%s?)\n",
				cudaGetErrorString(err));
		return -1;
	}
	return 0;
}

int main(void){
	unsigned gran = 64 * 1024;	// Granularity of report / verification
	unsigned unit = 4;		// Minimum alignment of references
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
		CUresult cerr;
		CUcontext ctx;
		int fd;

		printf(" %03d ",z);
		if(id_cuda(z,&mem,&tmem,&ctx)){
			cudaError_t err;

			err = cudaGetLastError();
			fprintf(stderr,"\nError probing CUDA device %d (%s?)\n",
					z,cudaGetErrorString(err));
			return EXIT_FAILURE;
		}
		if((fd = open("localhost.dump",O_RDWR|O_CREAT,S_IRUSR|S_IWUSR|S_IRGRP|S_IWGRP|S_IROTH)) < 0){
			fprintf(stderr,"\nError creating bitmap (%s?)\n",strerror(errno));
			cuCtxDetach(ctx);
			return EXIT_FAILURE;
		}
		if(dump_cuda(tmem,fd,unit,gran)){
			close(fd);
			cuCtxDetach(ctx);
			return EXIT_FAILURE;
		}
		if(close(fd)){
			fprintf(stderr,"\nError closing bitmap (%s?)\n",strerror(errno));
			cuCtxDetach(ctx);
			return EXIT_FAILURE;
		}
		if((cerr = cuCtxDetach(ctx)) != CUDA_SUCCESS){
			fprintf(stderr,"\nError detaching context (%d?)\n",cerr);
			return EXIT_FAILURE;
		}
	}
	return EXIT_SUCCESS;
}

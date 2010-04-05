#include <cuda.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <sys/time.h>
#include <driver_types.h>
#include <cuda_runtime_api.h>

// CUDA must already have been initialized before calling cudaid().
#define CUDASTRLEN 80
static int
id_cuda(int dev,unsigned *mem){
	struct cudaDeviceProp dprop;
	int major,minor,attr,cerr;
	void *str = NULL;
	unsigned tmem;
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
	if((cerr = cuMemGetInfo(mem,&tmem)) != CUDA_SUCCESS){
		cuCtxDetach(ctx);
		goto err;
	}
	if(printf("%d.%d %s %s %u/%uMB free %s\n",
		major,minor,
		dprop.integrated ? "Integrated" : "Standalone",(char *)str,
		*mem / (1024 * 1024) + !!(*mem / (1024 * 1024)),
		tmem / (1024 * 1024) + !!(tmem / (1024 * 1024)),
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
#define CHUNK (mem >> 5u) // FIXME kill
#define BLOCK_SIZE 64 // FIXME bigger would likely be better

__global__ void memkernel(unsigned *sum,unsigned b){
	__shared__ typeof(*sum) psum;
	typeof(sum) ptr;
	unsigned bp;

	psum = 0;
	for(ptr = (unsigned *)0x10000u ; ptr < sum ; ptr += BLOCK_SIZE){
		psum += ptr[threadIdx.x];
	}
	for(bp = 0 ; bp < b ; bp += BLOCK_SIZE){
		psum += *(typeof(sum))
			((uintmax_t)(sum + bp + threadIdx.x)
			 % (1lu << ADDRESS_BITS));
	}
	sum[threadIdx.x] = psum;
}

static int
dump_cuda(unsigned mem){
	unsigned sums[BLOCK_SIZE],sum = 0;
	struct timeval time0,time1,timer;
	dim3 dblock(BLOCK_SIZE,1,1);
	dim3 dgrid(1,1,1);
	void *ptr;

	printf(" Want %ub (0x%x) of %ub (0x%x)\n",mem - CHUNK,mem - CHUNK,mem,mem);
	if(cudaMalloc(&ptr,mem - CHUNK)){
		cudaError_t err;

		err = cudaGetLastError();
		fprintf(stderr,"Error initializing CUDA (%s?)\n",
				cudaGetErrorString(err));
		return EXIT_FAILURE;
	}
	printf(" Allocated %u MB at %p\n",(mem - CHUNK) / (1024 * 1024),ptr);
	gettimeofday(&time0,NULL);
	printf(" memkernel {%u x %u} x {%u x %u x %u} (%p, %zu)\n",
			dgrid.x,dgrid.y,dblock.x,dblock.y,dblock.z,
			(typeof(&sum))ptr,(mem - CHUNK) / sizeof(*sums));
	memkernel<<<dgrid,dblock>>>((typeof(&sum))ptr,(mem - CHUNK) / sizeof(*sums));
	if(cudaThreadSynchronize()){
		cudaError_t err;

		err = cudaGetLastError();
		fprintf(stderr,"Error running kernel (%s?)\n",
				cudaGetErrorString(err));
		return EXIT_FAILURE;
	}
	cudaMemcpy(sums,ptr,sizeof(sums),cudaMemcpyDeviceToHost);
	for(int i = 0 ; i < BLOCK_SIZE ; ++i){
		sum += sums[i];
	}
	gettimeofday(&time1,NULL);
	timersub(&time1,&time0,&timer);
	printf(" sum: %u\n",sum);
	printf(" elapsed time: %luus (%.3f MB/s)\n",
			timer.tv_sec * 1000000 + timer.tv_usec,
			(float)(mem - CHUNK) / (timer.tv_sec * 1000000 + timer.tv_usec));
	if(cudaFree(ptr) || cudaThreadSynchronize()){
		cudaError_t err;

		err = cudaGetLastError();
		fprintf(stderr,"Error dumping CUDA memory (%s?)\n",
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
		unsigned mem;

		printf(" %03d ",z);
		if(id_cuda(z,&mem)){
			cudaError_t err;

			err = cudaGetLastError();
			fprintf(stderr,"\nError probing CUDA device %d (%s?)\n",
					z,cudaGetErrorString(err));
			return EXIT_FAILURE;
		}
		if(dump_cuda(mem)){
			return EXIT_FAILURE;
		}
	}
	return EXIT_SUCCESS;
}

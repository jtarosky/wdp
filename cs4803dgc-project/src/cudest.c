#include "cudest.h"
#include <stdio.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/ioctl.h>

#define DEVROOT "/dev/nvidia"
#define NVCTLDEV "/dev/nvidiactl"

// Reverse-engineered from strace and binary analysis.
typedef enum {
	NV_HANDSHAKE	= 0xc04846d2,
	NV_SECOND	= 0xc00446ca,
	NV_THIRD	= 0xc60046c8,
	NV_FOURTH	= 0xc00c4622,
	NV_FIFTH	= 0xc020462a,
	NV_I6		= 0xc048464d,
	NV_I7		= 0xc014462d,
	NV_IA		= 0xc020462b,
} nvioctls;

typedef enum {
	NV_D0		= 0xc0204637,
	NV_D1		= 0xc0144632,
} nvdevioctls;

static int
Ioctl(int fd,int req,void *arg){
	uint32_t *dat = arg;
	int r,s,z;

	s = (req >> 16u) & 0x3fff;
	r = ioctl(fd,req,arg);
	printf("ioctl %x, %d-byte param, fd %d\t",req & 0xff,s,fd);
	if(r == 0){
		for(z = 0 ; z < s ; z += 4){
			printf("\x1b[1m");
			if(z % 16 == 0 && z){
				printf("0x%04x\t\t\t\t",z);
			}
			if(dat[z / 4]){
				printf("\x1b[32m");
			}
			printf("0x%08x ",dat[z / 4]);
			printf("\x1b[0m");
			if(z % 16 == 12){
				printf("\n");
			}
		}
		if(z % 16){
			printf("\n");
		}
	}
	printf("\n");
	return r;
}

// FIXME we'll almost certainly need a rwlock protecting this
static int nvctl = -1;

typedef struct nvhandshake {
	uint64_t ob[9];	// 0x48 bytes
} nvhandshake;

typedef uint32_t secondtype;

typedef struct thirdtype {
	uint32_t ob[384];	// 1536 (0x600) bytes
} thirdtype;

typedef struct fourthtype {
	uint32_t ob[3];		// 0xc (12) bytes
} fourthtype;

typedef struct type5 {
	uint32_t ob[8];		// 0x20 (32) bytes
} type5;

typedef struct type6 {
	uint32_t ob[12];	// 0x30 (48) bytes
} type6;

typedef struct typed0 {
	uint32_t ob[8];		// 0x20 (32) bytes
} typed0;

static type6 t6;
static thirdtype t3;
static fourthtype t4;
static type5 t5,ta,t7;
static secondtype result0xca;

static CUresult
init_dev(unsigned dno){
	char devn[strlen(DEVROOT) + 4];
	typed0 td0;
	int dfd;

	if(snprintf(devn,sizeof(devn),"%s%u",DEVROOT,dno) >= (int)sizeof(devn)){
		return CUDA_ERROR_INVALID_VALUE;
	}
	if((dfd = open(devn,O_RDWR)) < 0){
		return CUDA_ERROR_INVALID_DEVICE;
	}
	td0.ob[0] = 3251636241;
	td0.ob[1] = 3251636241;
	td0.ob[2] = 1;
	td0.ob[3] = 0;
	td0.ob[4] = 0;
	if(Ioctl(dfd,NV_D0,&td0)){
		close(dfd);
		return CUDA_ERROR_INVALID_DEVICE;
	}
	if(Ioctl(dfd,NV_D0,&td0)){
		close(dfd);
		return CUDA_ERROR_INVALID_DEVICE;
	}
	close(dfd);
	return CUDA_SUCCESS;
}

static CUresult
init_ctlfd(int fd){
	nvhandshake hshake;
	CUresult r;

	memset(&hshake,0,sizeof(hshake));
	hshake.ob[2] = 0x35ull;
	hshake.ob[1] = 0x312e36332e353931ull;
	if(Ioctl(fd,NV_HANDSHAKE,&hshake)){
		return CUDA_ERROR_INVALID_DEVICE;
	}
	if(Ioctl(fd,NV_SECOND,&result0xca)){
		return CUDA_ERROR_INVALID_DEVICE;
	}
	t3.ob[0] = (uint32_t)-1;
	if(Ioctl(fd,NV_THIRD,&t3)){
		return CUDA_ERROR_INVALID_DEVICE;
	}
	if(Ioctl(fd,NV_FOURTH,&t4)){
		return CUDA_ERROR_INVALID_DEVICE;
	}
	// FIXME ought be setting the rest of this up
	t5.ob[0] = t4.ob[0];
	t5.ob[1] = t4.ob[0];
	if(Ioctl(fd,NV_FIFTH,&t5)){
		return CUDA_ERROR_INVALID_DEVICE;
	}
	if(Ioctl(fd,NV_I6,&t6)){
		return CUDA_ERROR_INVALID_DEVICE;
	}
	if(Ioctl(fd,NV_FIFTH,&t5)){
		return CUDA_ERROR_INVALID_DEVICE;
	}
	if(Ioctl(fd,NV_FIFTH,&t5)){
		return CUDA_ERROR_INVALID_DEVICE;
	}
	if(Ioctl(fd,NV_FIFTH,&t5)){
		return CUDA_ERROR_INVALID_DEVICE;
	}
	if(Ioctl(fd,NV_IA,&ta)){
		return CUDA_ERROR_INVALID_DEVICE;
	}
	if((r = init_dev(0)) != CUDA_SUCCESS){
		return r;
	}
	if(Ioctl(fd,NV_FIFTH,&t5)){
		return CUDA_ERROR_INVALID_DEVICE;
	}
	if(Ioctl(fd,NV_FIFTH,&t5)){
		return CUDA_ERROR_INVALID_DEVICE;
	}
	if(Ioctl(fd,NV_FIFTH,&t5)){
		return CUDA_ERROR_INVALID_DEVICE;
	}
	if(Ioctl(fd,NV_FIFTH,&t5)){
		return CUDA_ERROR_INVALID_DEVICE;
	}
	if(Ioctl(fd,NV_I7,&t7)){
		return CUDA_ERROR_INVALID_DEVICE;
	}
	if(Ioctl(fd,NV_FIFTH,&t5)){
		return CUDA_ERROR_INVALID_DEVICE;
	}
	return CUDA_SUCCESS;
}

CUresult cuInit(unsigned flags){
	CUresult r;
	int fd;

	if(flags){
		return CUDA_ERROR_INVALID_VALUE;
	}
	if((fd = open(NVCTLDEV,O_RDWR)) < 0){
		return CUDA_ERROR_INVALID_DEVICE;
	}
	if((r = init_ctlfd(fd)) != CUDA_SUCCESS){
		close(fd);
		return r;
	}
	if(nvctl >= 0){
		close(nvctl);
	}
	nvctl = fd;
	return CUDA_SUCCESS;
}

CUresult cuDeviceGet(CUdevice *d,int devno){
	if(devno < 0){
		return CUDA_ERROR_INVALID_VALUE;
	}
	d->devno = devno;
	return CUDA_SUCCESS;
}

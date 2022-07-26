/* A simple event-driven programming library. Originally I wrote this code
 * for the Jim's event-loop (Jim is a Tcl interpreter) but later translated
 * it in form of a library for easy reuse.
 *
 * Copyright (c) 2006-2012, Salvatore Sanfilippo <antirez at gmail dot com>
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 *   * Redistributions of source code must retain the above copyright notice,
 *     this list of conditions and the following disclaimer.
 *   * Redistributions in binary form must reproduce the above copyright
 *     notice, this list of conditions and the following disclaimer in the
 *     documentation and/or other materials provided with the distribution.
 *   * Neither the name of Redis nor the names of its contributors may be used
 *     to endorse or promote products derived from this software without
 *     specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 */

#ifndef __AE_H__
#define __AE_H__

#include <time.h>

#define AE_OK 0
#define AE_ERR -1

#define AE_NONE 0       /* No events registered. */
#define AE_READABLE 1   /* 当文件描述符可读时触发 */
#define AE_WRITABLE 2   /* 当文件描述符可写时触发 */
/* 
    屏障事件，在同一次事件循环迭代中，如果可读事件已经触发了，那么可写事件就不会被触发
    当你想要发送回复之前先持久化到磁盘，并且想以组的方式做这件事就很有用
 */
#define AE_BARRIER 4

#define AE_FILE_EVENTS 1
#define AE_TIME_EVENTS 2
#define AE_ALL_EVENTS (AE_FILE_EVENTS|AE_TIME_EVENTS)
#define AE_DONT_WAIT 4
#define AE_CALL_AFTER_SLEEP 8

#define AE_NOMORE -1
#define AE_DELETED_EVENT_ID -1

/* Macros */
#define AE_NOTUSED(V) ((void) V)

struct aeEventLoop;

/* Types and data structures */
typedef void aeFileProc(struct aeEventLoop *eventLoop, int fd, void *clientData, int mask);
typedef int aeTimeProc(struct aeEventLoop *eventLoop, long long id, void *clientData);
typedef void aeEventFinalizerProc(struct aeEventLoop *eventLoop, void *clientData);
typedef void aeBeforeSleepProc(struct aeEventLoop *eventLoop);

/* 
    IO事件结构体，之所以类型名称为aeFileEvent，
    是因为所有的IO事件都会用文件描述符进行标识 
*/
typedef struct aeFileEvent {
    int mask;   /* AE_(READABLE|WRITABLE|BARRIER) 之一， 框架在分发事件时，依赖的就是结构体中的事件类型 */
    aeFileProc *rfileProc;  /* 指向 AE_READABLE事件的处理函数，框架在分发事件后，需要调用结构体中定义的函数进行事件处理 */
    aeFileProc *wfileProc;  /* 指向 AE_WRITABLE事件的处理函数，框架在分发事件后，需要调用结构体中定义的函数进行事件处理 */
    void *clientData;       /* 指向客户端私有数据的指针*/
} aeFileEvent;

/* Time event structure */
typedef struct aeTimeEvent {
    long long id; /* 事件事件id. */
    long when_sec; /* 事件到达的秒级时间戳 */
    long when_ms; /* 事件到达的毫秒级时间戳 */
    aeTimeProc *timeProc; /* 时间事件触发后的处理函数 */
    aeEventFinalizerProc *finalizerProc; /* 事件处理后的处理函数 */
    void *clientData;   /* 事件相关的私有数据 */
    struct aeTimeEvent *prev;   /* 时间事件链表的前向指针 */
    struct aeTimeEvent *next;   /* 时间事件链表的后向指针 */
} aeTimeEvent;

/* A fired event */
typedef struct aeFiredEvent {
    int fd;
    int mask;
} aeFiredEvent;

/* 基于事件的程序状态，记录了框架循环运行过程中的信息 */
typedef struct aeEventLoop {
    int maxfd;   /* highest file descriptor currently registered */
    int setsize; /* max number of file descriptors tracked */
    long long timeEventNextId;
    time_t lastTime;     /* Used to detect system clock skew */
    aeFileEvent *events; /* 注册的事件，表示IO事件组 */
    aeFiredEvent *fired; /* 用来记录已触发事件对应的文件描述符信息 */
    aeTimeEvent *timeEventHead; /* 表示时间事件，即按一定时间周期触发的事件 */
    int stop;
    void *apidata; /* 和API调用接口相关的数据 */
    aeBeforeSleepProc *beforesleep; /* 进入事件循环流程前执行的函数 */
    aeBeforeSleepProc *aftersleep;  /* 退出事件循环流程后执行的函数 */
} aeEventLoop;

/* Prototypes */
aeEventLoop *aeCreateEventLoop(int setsize);
void aeDeleteEventLoop(aeEventLoop *eventLoop);
void aeStop(aeEventLoop *eventLoop);
/* 负责事件和handler注册 */
int aeCreateFileEvent(aeEventLoop *eventLoop, int fd, int mask,
        aeFileProc *proc, void *clientData);
void aeDeleteFileEvent(aeEventLoop *eventLoop, int fd, int mask);
int aeGetFileEvents(aeEventLoop *eventLoop, int fd);
long long aeCreateTimeEvent(aeEventLoop *eventLoop, long long milliseconds,
        aeTimeProc *proc, void *clientData,
        aeEventFinalizerProc *finalizerProc);
int aeDeleteTimeEvent(aeEventLoop *eventLoop, long long id);
/* 负责事件捕获与分发 */
int aeProcessEvents(aeEventLoop *eventLoop, int flags);
int aeWait(int fd, int mask, long long milliseconds);
/* 框架主循环函数 */
void aeMain(aeEventLoop *eventLoop);
char *aeGetApiName(void);
void aeSetBeforeSleepProc(aeEventLoop *eventLoop, aeBeforeSleepProc *beforesleep);
void aeSetAfterSleepProc(aeEventLoop *eventLoop, aeBeforeSleepProc *aftersleep);
int aeGetSetSize(aeEventLoop *eventLoop);
int aeResizeSetSize(aeEventLoop *eventLoop, int setsize);

#endif

//
//  DNWebSocketManager.m
//  DNProject
//
//  Created by zjs on 2019/2/18.
//  Copyright © 2019 zjs. All rights reserved.
//

#import "DNWebSocketManager.h"
#import <SRWebSocket.h>

// 主线程异步队列
#define dispatch_main_async_safe(block)\
if ([NSThread isMainThread]) {\
block();\
} else {\
dispatch_async(dispatch_get_main_queue(), block);\
}

static NSString *s_host = @"ws://118.31.12.178/websocket";
static NSString *s_port = @"";

@interface DNWebSocketManager ()<SRWebSocketDelegate>

@property (nonatomic, strong) SRWebSocket *webSocket;

@property (nonatomic, strong) NSTimer *heartBeatTimer;
@property (nonatomic, strong) NSTimer *networkCheckTimer;

@property (nonatomic, strong) dispatch_queue_t queue; //数据请求队列（串行队列

@property (nonatomic, assign) NSTimeInterval reConnectTime; //重连时间
@property (nonatomic, strong) NSMutableArray *sendDataArray; //存储要发送给服务端的数据
//用于判断是否主动关闭长连接，如果是主动断开连接，连接失败的代理中，就不用执行 重新连接方法
@property (nonatomic, assign) BOOL isActivelyClose;

@end

static DNWebSocketManager *_shareManager = nil;

@implementation DNWebSocketManager

+ (instancetype)defaultManager {
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (!_shareManager) {
            
            _shareManager = [[self alloc] init];
        }
    });
    return _shareManager;
}

- (instancetype)init {
    self = [super init];
    if(self) {
        self.reConnectTime = 0;
        self.isActivelyClose = NO;
        self.queue = dispatch_queue_create("BF",NULL);
        self.sendDataArray = [[NSMutableArray alloc] init];
    }
    return self;
}

#pragma mark - NSTimer
//初始化心跳
- (void)initHeartBeat {
    //心跳没有被关闭
    if(self.heartBeatTimer) {
        return;
    }
    [self destoryHeartBeat];
    
    __weak typeof(self) weakself = self;
    dispatch_main_async_safe(^{
        weakself.heartBeatTimer  = [NSTimer timerWithTimeInterval:10
                                                           target:weakself
                                                         selector:@selector(senderheartBeat)
                                                         userInfo:nil
                                                          repeats:true];
        [[NSRunLoop currentRunLoop] addTimer:weakself.heartBeatTimer forMode:NSRunLoopCommonModes];
    });
}

//取消心跳
- (void)destoryHeartBeat {
    
    __weak typeof(self) weakself = self;
    
    dispatch_main_async_safe(^{
        if(weakself.heartBeatTimer) {
            [weakself.heartBeatTimer invalidate];
            weakself.heartBeatTimer = nil;
        }
    });
}

//没有网络的时候开始定时 -- 用于网络检测
- (void)noNetWorkStartTestingTimer {
    
    __weak typeof(self) weakself = self;
    
    dispatch_main_async_safe(^{
        
        weakself.networkCheckTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                                      target:weakself
                                                                    selector:@selector(noNetWorkStartTesting)
                                                                    userInfo:nil
                                                                     repeats:YES];
        [[NSRunLoop currentRunLoop] addTimer:weakself.networkCheckTimer forMode:NSDefaultRunLoopMode];
    });
}

//取消网络检测
- (void)destoryNetWorkStartTesting {
    
    __weak typeof(self) weakself = self;
    
    dispatch_main_async_safe(^{
        
        if(weakself.networkCheckTimer) {
            [weakself.networkCheckTimer invalidate];
            weakself.networkCheckTimer = nil;
        }
    });
}

#pragma mark - private -- webSocket相关方法
//发送心跳
- (void)senderheartBeat {
    //和服务端约定好发送什么作为心跳标识，尽可能的减小心跳包大小
    __weak typeof(self) weakself = self;
    
    dispatch_main_async_safe(^{
        if(weakself.webSocket.readyState == SR_OPEN) {
            
            [weakself.webSocket sendPing:nil];
        }
    });
}

//定时检测网络
- (void)noNetWorkStartTesting {
    //有网络
    if(AFNetworkReachabilityManager.sharedManager.networkReachabilityStatus != AFNetworkReachabilityStatusNotReachable) {
        //关闭网络检测定时器
        [self destoryNetWorkStartTesting];
        //开始重连
        [self reConnectServer];
    }
}

//建立长连接
- (void)connectServer {
    self.isActivelyClose = NO;
    
    if(self.webSocket) {
        self.webSocket = nil;
    }
    
    NSString *ip = [NSString stringWithFormat:@"%@%@", s_host, s_port];
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:ip]];
    self.webSocket = [[SRWebSocket alloc] initWithURLRequest:request];
    self.webSocket.delegate = self;
    [self.webSocket open];
}

//重新连接服务器
- (void)reConnectServer {
    
    if(self.webSocket.readyState == SR_OPEN) {
        return;
    }
    //重连10次 2^10 = 1024
    if(self.reConnectTime > 1024) {
        self.reConnectTime = 0;
        return;
    }
    
    __weak typeof(self) weakself = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.reConnectTime *NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        
        if(weakself.webSocket.readyState == SR_OPEN && weakself.webSocket.readyState == SR_CONNECTING) {
            return;
        }
        
        [weakself connectServer];
        NSLog(@"正在重连......");
        //重连时间2的指数级增长
        if(weakself.reConnectTime == 0) {
            weakself.reConnectTime = 2;
        }
        else {
            weakself.reConnectTime *= 2;
        }
    });
    
}

//关闭连接
- (void)SRWebSocketClose {
    
    self.isActivelyClose = YES;
    [self webSocketClose];
    //关闭心跳定时器
    [self destoryHeartBeat];
    //关闭网络检测定时器
    [self destoryNetWorkStartTesting];
}
//关闭连接
- (void)webSocketClose {
    
    if(self.webSocket) {
        [self.webSocket close];
        self.webSocket = nil;
    }
}

//发送数据给服务器
- (void)sendDataToServer:(id)data {
    
    [self.sendDataArray addObject:data];
    [self sendeDataToServer];
}
- (void)sendeDataToServer {
    
    __weak typeof(self) weakself = self;
    //把数据放到一个请求队列中
    dispatch_async(self.queue, ^{
        
        //没有网络
        if (AFNetworkReachabilityManager.sharedManager.networkReachabilityStatus == AFNetworkReachabilityStatusNotReachable) {
            //开启网络检测定时器
            [weakself noNetWorkStartTestingTimer];
        }
        //有网络
        else {
            if(weakself.webSocket != nil) {
                // 只有长连接OPEN开启状态才能调 send 方法，不然会Crash
                if(weakself.webSocket.readyState == SR_OPEN) {
                    
                    if (weakself.sendDataArray.count > 0) {
                        
                        NSString *data = weakself.sendDataArray[0];
                        //发送数据
                        [weakself.webSocket send:data];
                        [weakself.sendDataArray removeObjectAtIndex:0];

                        if([weakself.sendDataArray count] > 0) {

                            [weakself sendeDataToServer];
                        }
                    }
                }
                //正在连接
                else if (weakself.webSocket.readyState == SR_CONNECTING) {
                    NSLog(@"正在连接中，重连后会去自动同步数据");
                }
                //断开连接
                else if (weakself.webSocket.readyState == SR_CLOSING || weakself.webSocket.readyState == SR_CLOSED) {
                    //调用 reConnectServer 方法重连,连接成功后 继续发送数据
                    [weakself reConnectServer];
                }
            }
            else {
                //连接服务器
                [weakself connectServer];
            }
        }
    });
}

#pragma mark - SRWebSocketDelegate -- webSockect代理
//连接成功回调
- (void)webSocketDidOpen:(SRWebSocket *)webSocket {
    
    DNLog(@"webSocket ------> 连接成功");
    //开启心跳
    [self initHeartBeat];
    //如果有尚未发送的数据，继续向服务端发送数据
    if ([self.sendDataArray count] > 0) {
        [self sendeDataToServer];
    }
}

//连接失败回调
- (void)webSocket:(SRWebSocket *)webSocket didFailWithError:(NSError *)error {
    //用户主动断开连接，就不去进行重连
    if(self.isActivelyClose) {
        return;
    }
    //断开连接时销毁心跳
    [self destoryHeartBeat];
    
    DNLog(@"连接失败，这里可以实现掉线自动重连，要注意以下几点")
    DNLog(@"1.判断当前网络环境，如果断网了就不要连了，等待网络到来，在发起重连")
    DNLog(@"2.连接次数限制，如果连接失败了，重试10次左右就可以了")
    //判断网络环境
    if (AFNetworkReachabilityManager.sharedManager.networkReachabilityStatus == AFNetworkReachabilityStatusNotReachable) {
        //没有网络时开启网络检测定时器
        [self noNetWorkStartTestingTimer];
    }
    //有网络
    else {
        // 连接失败就重连
        [self reConnectServer];
    }
}

//连接关闭,注意连接关闭不是连接断开，关闭是 [socket close] 客户端主动关闭，断开可能是断网了，被动断开的。
- (void)webSocket:(SRWebSocket *)webSocket didCloseWithCode:(NSInteger)code reason:(NSString *)reason wasClean:(BOOL)wasClean {
    // 在这里判断 webSocket 的状态 是否为 open , 大家估计会有些奇怪 ，因为我们的服务器都在海外，会有些时间差，经过测试，我们在进行某次连接的时候，上次重连的回调刚好回来，而本次重连又成功了，就会误以为，本次没有重连成功，而再次进行重连，就会出现问题，所以在这里做了一下判断
    if(self.webSocket.readyState == SR_OPEN || self.isActivelyClose) {
        return;
    }
    
    DNLog(@"被关闭连接，code:%ld,reason:%@,wasClean:%d",(long)code,reason,wasClean)
    
    [self destoryHeartBeat]; //断开连接时销毁心跳
    
    //判断网络环境
    if (AFNetworkReachabilityManager.sharedManager.networkReachabilityStatus == AFNetworkReachabilityStatusNotReachable) {
        // 没有网络是开启网络检测
        [self noNetWorkStartTestingTimer];
    }
    // 有网络
    else {
        //连接失败就重连
        [self reConnectServer];
    }
}

//该函数是接收服务器发送的pong消息，其中最后一个参数是接受pong消息的
-(void)webSocket:(SRWebSocket *)webSocket didReceivePong:(NSData*)pongPayload {
    
    NSString* reply = [[NSString alloc] initWithData:pongPayload encoding:NSUTF8StringEncoding];
    DNLog(@"reply === 收到后台心跳回复 Data:%@",reply);
}

//收到服务器发来的数据
- (void)webSocket:(SRWebSocket *)webSocket didReceiveMessage:(id)message {
//    NSDictionary *dataDic = [self dictionaryWithJsonString:message];
//
//    DNLog(@"%@", dataDic);
    /*根据具体的业务做具体的处理*/
}

@end

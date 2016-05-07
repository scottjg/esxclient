//
//  VMwareMksVncProxy.swift
//  esxclient
//
//  Created by Scott Goldman on 4/9/16.
//  Copyright © 2016 scottjg. All rights reserved.
//

import CoreFoundation
import Foundation
import Cocoa

class VMwareMksVncProxy : NSObject, NSStreamDelegate {
    var vmwareHost, sessionTicket, vmCfgFile, vmwareSslThumbprint : String
    var vmwarePort : UInt16
    
    var vmwInputStream: NSInputStream?
    var vmwOutputStream: NSOutputStream?
    var clientInputStream: NSInputStream?
    var clientOutputStream: NSOutputStream?
    
    var sslCtx: SSLContext?
    
    var vncServerSocket : CFSocket?
    var vncClientSocketFd: CFSocketNativeHandle = -1

    var selfPtr: UnsafeMutablePointer<VMwareMksVncProxy> = nil
    
    init(host: String, ticket: String, cfgFile: String, port: UInt16, sslThumbprint: String) {
        self.vmwareHost = host
        self.vmwarePort = port
        self.sessionTicket = ticket
        self.vmCfgFile = cfgFile
        self.vmwareSslThumbprint = sslThumbprint

        super.init()

        self.selfPtr = UnsafeMutablePointer<VMwareMksVncProxy>.alloc(1)
        selfPtr.initialize(self)
    }
    
    deinit {
        selfPtr.dealloc(1)
    }

    func setupVncProxyServerPort(callback: (port: UInt16) -> Void) {
        self.connectToAuthd()
        self.negotiateMksSession()

        let port = startVncProxyServer()
        callback(port: port)
    }
    
    func negotiateMksSession() {
        var readBuffer = [UInt8](count: 8192, repeatedValue: 0)
        
        /*
         < 220 VMware Authentication Daemon Version 1.10: SSL Required, ServerDaemonProtocol:SOAP, MKSDisplayProtocol:VNC , VMXARGS supported, NFCSSL supported
         */
        let size = self.vmwInputStream?.read(&readBuffer, maxLength: readBuffer.count)
        
        let str = String(data: NSData(bytes: readBuffer, length: size!), encoding: NSUTF8StringEncoding)!
        print(str)
        let ctx = SSLCreateContext(kCFAllocatorDefault, SSLProtocolSide.ClientSide, SSLConnectionType.StreamType)
        
        SSLSetSessionOption(ctx!, SSLSessionOption.BreakOnServerAuth, true)
        SSLSetIOFuncs(ctx!, sslReadCallback, sslWriteCallback)
        
        SSLSetConnection(ctx!, self.selfPtr)
        
        let r1 = SSLHandshake(ctx!)
        if r1 != -9841 { //errSSLServerAuthCompleted {
            fatalError("weird server error \(r1)")
        }
        let r2 = SSLHandshake(ctx!)
        
        /*
         > USER 52cf8c64-9343-7cb7-d151-1bfc481bb7d5
         */
        
        var written : Int = 0
        let loginMessage = "USER \(self.sessionTicket)\r\n".dataUsingEncoding(NSUTF8StringEncoding)
        let r3 = SSLWrite(ctx!, loginMessage!.bytes, loginMessage!.length, &written)
        
        /*
         < 331 Password required for 52cf8c64-9343-7cb7-d151-1bfc481bb7d5.
         */
        
        let r4 = SSLRead(ctx!, &readBuffer, 8192, &written)
        let str1 = String(data: NSData(bytes: readBuffer, length: written), encoding: NSUTF8StringEncoding)!
        print(str1)
        
        /*
         > PASS 52cf8c64-9343-7cb7-d151-1bfc481bb7d5
         */
        
        let passMessage = "PASS \(self.sessionTicket)\r\n".dataUsingEncoding(NSUTF8StringEncoding)
        let r5 = SSLWrite(ctx!, passMessage!.bytes, passMessage!.length, &written)
        
        /*
         < 230 User 52cf8c64-9343-7cb7-d151-1bfc481bb7d5 logged in.
         */
        
        let r6 = SSLRead(ctx!, &readBuffer, 8192, &written)
        let str2 = String(data: NSData(bytes: readBuffer, length: written), encoding: NSUTF8StringEncoding)!
        print(str2)
        
        /*
         > THUMBPRINT <b64 encode 12 random bytes>
         */
        
        let thumbprintMessage = "THUMBPRINT eJBwxqmgapMm7Nom\r\n".dataUsingEncoding(NSUTF8StringEncoding)
        let r7 = SSLWrite(ctx!, thumbprintMessage!.bytes, thumbprintMessage!.length, &written)
        
        /*
         < 200 C5:50:62:9F:97:1D:AF:96:91:0B:2D:0E:2A:CA:2E:52:FB:60:87:73
         */
        
        let r8 = SSLRead(ctx!, &readBuffer, 8192, &written)
        let str3 = String(data: NSData(bytes: readBuffer, length: written), encoding: NSUTF8StringEncoding)!
        print(str3)
        
        /*
         > CONNECT <vmfs path> mks\r\n
         */
        
        let connectMessage = "CONNECT \(self.vmCfgFile) mks\r\n".dataUsingEncoding(NSUTF8StringEncoding)
        let r9 = SSLWrite(ctx!, connectMessage!.bytes, connectMessage!.length, &written)
        
        /*
         < Connect /vmfs/volumes/56d5c29a-ac1ca31f-fd75-089e01d8b64c/scottjg-enterprise2-test/scottjg-enterprise2-test.vmx
         */
        
        let r10 = SSLRead(ctx!, &readBuffer, 8192, &written)
        let str4 = String(data: NSData(bytes: readBuffer, length: written), encoding: NSUTF8StringEncoding)!
        print(str4)
        
        // this is weird but at this point in the protocol we have to redo the ssl handshake
        
        self.sslCtx = SSLCreateContext(kCFAllocatorDefault, SSLProtocolSide.ClientSide, SSLConnectionType.StreamType)
        
        SSLSetSessionOption(self.sslCtx!, SSLSessionOption.BreakOnServerAuth, true)
        SSLSetIOFuncs(self.sslCtx!, sslReadCallback, sslWriteCallback)
        SSLSetConnection(self.sslCtx!, self.selfPtr)
        
        let r11 = SSLHandshake(self.sslCtx!)
        if r11 != -9841 { //errSSLServerAuthCompleted {
            fatalError("weird server error \(r11)")
        }
        let r12 = SSLHandshake(self.sslCtx!)

        let randomMessage = "eJBwxqmgapMm7Nom".dataUsingEncoding(NSUTF8StringEncoding)
        let r13 = SSLWrite(self.sslCtx!, randomMessage!.bytes, randomMessage!.length, &written)
    }
    
    func connectToAuthd() {
        var readStream: Unmanaged<CFReadStreamRef>?
        var writeStream: Unmanaged<CFWriteStreamRef>?
        CFStreamCreatePairWithSocketToHost(nil, self.vmwareHost, UInt32(self.vmwarePort), &readStream, &writeStream);
        
        self.vmwInputStream = readStream!.takeRetainedValue()
        self.vmwInputStream?.delegate = self
        //self.vmwInputStream?.scheduleInRunLoop(.mainRunLoop(), forMode: NSDefaultRunLoopMode)
        self.vmwInputStream?.open()

        self.vmwOutputStream = writeStream!.takeRetainedValue()
        self.vmwOutputStream?.delegate = self
        //self.vmwOutputStream?.scheduleInRunLoop(.mainRunLoop(), forMode: NSDefaultRunLoopMode)
        self.vmwOutputStream?.open()
    }
    
    func startVncProxyServer() -> UInt16 {
        var socketContext = CFSocketContext()
        socketContext.info = UnsafeMutablePointer<Void>(selfPtr)

        self.vncServerSocket = CFSocketCreate(kCFAllocatorDefault, PF_INET, SOCK_STREAM, IPPROTO_TCP, CFSocketCallBackType.AcceptCallBack.rawValue, acceptVncClientConnection, &socketContext)
        
        let fd = CFSocketGetNative(self.vncServerSocket)
        var reuse = true
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(sizeof(Int32)))
        
        var addr = sockaddr_in(sin_len: 0, sin_family: 0, sin_port: 0, sin_addr: in_addr(s_addr: 0), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        addr.sin_len = UInt8(sizeofValue(addr))
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = UInt32(0x7F000001).bigEndian
        //addr.sin_port = UInt16(12345).bigEndian
        
        let ptr = withUnsafeMutablePointer(&addr){UnsafeMutablePointer<UInt8>($0)}
        let data = CFDataCreate(nil, ptr, sizeof(sockaddr_in))
        let r = CFSocketSetAddress(self.vncServerSocket, data)
        
        
        var addrLen = socklen_t(sizeofValue(addr))
        withUnsafeMutablePointers(&addr, &addrLen) { (sinPtr, addrPtr) -> Int32 in
            getsockname(fd, UnsafeMutablePointer(sinPtr), UnsafeMutablePointer(addrPtr))
        }
        let port = addr.sin_port.bigEndian
        print("assigned port \(port)")
        
        
        let eventSource = CFSocketCreateRunLoopSource(
            kCFAllocatorDefault,
            self.vncServerSocket,
            0);
        
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            eventSource,
            kCFRunLoopDefaultMode);
        
        print("waiting for incoming connection...")
        return port
    }
    
    func handleVncProxyClient(inputStream : NSInputStream, outputStream : NSOutputStream) {
        let msg = [UInt8]("RFB 003.008\n".utf8)
        let r1 = outputStream.write(msg, maxLength: msg.count)
        
        
        var buffer = [UInt8](count: 8192, repeatedValue: 0)
        let size = inputStream.read(&buffer, maxLength: buffer.count)
        print(NSString(bytes: buffer, length: size, encoding: NSUTF8StringEncoding)!)
        
        buffer[0] = 0x00
        buffer[1] = 0x00
        buffer[2] = 0x00
        buffer[3] = 0x01
        let r2 = outputStream.write(buffer, maxLength: 4)
        
        let r3 = outputStream.write(buffer, maxLength: 16)
        
        
        let size1 = inputStream.read(&buffer, maxLength: buffer.count)
        if (size1 == 0) {
            inputStream.close()
            outputStream.close()
            print("disconnected")
            return
        }
        print("(client auth) got \(size1) bytes")
        
        //SecurityResult
        buffer[0] = 0x00
        buffer[1] = 0x00
        buffer[2] = 0x00
        buffer[3] = 0x00
        let r4 = outputStream.write(buffer, maxLength: 4)
        
        let size3 = inputStream.read(&buffer, maxLength: 4)
        print("(client init) got \(size3) bytes")
        
        // ok now we have to proxy the actual vnc stuff from esx
        print("client is ready for video, proxying..")

        
        self.clientOutputStream = outputStream
        self.clientInputStream = inputStream
        self.clientInputStream?.delegate = self

        // enable async callbacks for proxying
        self.clientInputStream?.scheduleInRunLoop(.mainRunLoop(), forMode: NSDefaultRunLoopMode)
        self.vmwInputStream?.scheduleInRunLoop(.mainRunLoop(), forMode: NSDefaultRunLoopMode)
        
        //pump the sockets to begin
        self.stream(self.vmwInputStream!, handleEvent: NSStreamEvent.HasBytesAvailable)
    }
    
    func stream(aStream: NSStream, handleEvent eventCode: NSStreamEvent) {
        if aStream.isEqual(self.vmwInputStream) {
            //print("vmwinputstream event!")
            if self.clientOutputStream == nil {
                print("not ready!")
                return
            }
            while self.vmwInputStream!.hasBytesAvailable {
                var buffer = [UInt8](count: 8192, repeatedValue: 0)
                var readSize : Int = 0
                let r = SSLRead(self.sslCtx!, &buffer, buffer.count, &readSize)
                //print ("vmw read: \(readSize): \(buffer[0]) \(buffer[1])")
                if r == errSSLWouldBlock {
                    continue
                }
                //assert(readSize > 0)
                if readSize <= 0 {
                    print("server disconnected")
                    self.cleanup()
                    return
                }
                
                let written = self.clientOutputStream?.write(buffer, maxLength: readSize)
                assert(written == readSize)
            }
        } else if aStream.isEqual(self.clientInputStream) {
            //print("clientinputstream event!")
            while self.clientInputStream!.hasBytesAvailable {
                var buffer = [UInt8](count: 8192, repeatedValue: 0)
                let readSize = self.clientInputStream?.read(&buffer, maxLength: buffer.count)
                //print ("client read: \(readSize)")
                //assert(readSize > 0)
                if readSize <= 0 {
                    print("client disconnected")
                    self.cleanup()
                    return
                }

                var written : Int = 0
                SSLWrite(self.sslCtx!, buffer, readSize!, &written)
                assert(written == readSize!)
            }
        } else {
            print("unknown stream event!")
        }
    }
    
    func cleanup() {
        SSLClose(self.sslCtx!)
        self.sslCtx = nil

        self.vmwInputStream!.close()
        self.vmwInputStream = nil

        self.vmwOutputStream!.close()
        self.vmwOutputStream = nil

        self.clientInputStream!.close()
        self.clientInputStream = nil

        self.clientOutputStream!.close()
        self.clientOutputStream = nil

        if self.vncClientSocketFd > 0 {
            close(self.vncClientSocketFd)
            self.vncClientSocketFd = -1
        }
    }
}

func acceptVncClientConnection(s: CFSocket!, callbackType: CFSocketCallBackType, address: CFData!, data: UnsafePointer<Void>, info: UnsafeMutablePointer<Void>) {
    let delegate = UnsafeMutablePointer<VMwareMksVncProxy>(info).memory
    
    let sockAddr = UnsafePointer<sockaddr_in>(CFDataGetBytePtr(address))
    let ipAddress = inet_ntoa(sockAddr.memory.sin_addr)
    let addrData = NSData(bytes: ipAddress, length: Int(INET_ADDRSTRLEN))
    let ipAddressStr = NSString(data: addrData, encoding: NSUTF8StringEncoding)!
    print("Received a connection from \(ipAddressStr)")
    
    let clientSocketHandle = UnsafePointer<CFSocketNativeHandle>(data).memory
    
    var readStream : Unmanaged<CFReadStream>?
    var writeStream : Unmanaged<CFWriteStream>?
    CFStreamCreatePairWithSocket(kCFAllocatorDefault, clientSocketHandle, &readStream, &writeStream)
    delegate.vncClientSocketFd = clientSocketHandle
    
    let inputStream : NSInputStream = readStream!.takeRetainedValue()
    let outputStream : NSOutputStream = writeStream!.takeRetainedValue()
    
    inputStream.open()
    outputStream.open()
    
    if delegate.vmwInputStream == nil {
        delegate.connectToAuthd()
        delegate.negotiateMksSession()
    }
    
    delegate.handleVncProxyClient(inputStream, outputStream: outputStream)
}

func sslReadCallback(connection: SSLConnectionRef,
                     data: UnsafeMutablePointer<Void>,
                     dataLength: UnsafeMutablePointer<Int>) -> OSStatus {
    let delegate = UnsafeMutablePointer<VMwareMksVncProxy>(connection).memory
    let inputStream = delegate.vmwInputStream!
    let expectedReadSize = dataLength.memory
    let size = inputStream.read(UnsafeMutablePointer<UInt8>(data), maxLength: expectedReadSize)
    dataLength.memory = size
    if (size == 0) {
        return Int32(errSSLClosedGraceful)
    } else if (size < expectedReadSize) {
        //print("would have blocked. read \(size) of \(expectedReadSize)")
        return Int32(errSSLWouldBlock)
    }
    
    return 0
}

func sslWriteCallback(connection: SSLConnectionRef,
                      data: UnsafePointer<Void>,
                      dataLength: UnsafeMutablePointer<Int>) -> OSStatus {
    let delegate = UnsafeMutablePointer<VMwareMksVncProxy>(connection).memory
    let outputStream = delegate.vmwOutputStream!
    
    outputStream.write(UnsafePointer<UInt8>(data), maxLength: dataLength.memory)
    return 0
}

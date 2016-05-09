//
//  VMwareMksVncProxy.swift
//  esxclient
//
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
    var vncServerSocketEventSource: CFRunLoopSource? = nil
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
        // setup a random port to listen for a vnc client
        let port = self.startVncProxyServer()

        // tell the application that the port is ready
        // (and to presumably start the vnc client)
        callback(port: port)
    }

    func handleVncProxyClient(inputStream : NSInputStream, outputStream : NSOutputStream) {
        // this runs when the vnc client connects to our proxy port.
        // the vmware mks protocol is similar to vnc, but it starts
        // slightly different. so we pretend to be the vnc server at
        // the beginning to get the client ready, while also pretending
        // to be a vmware mks client to the vmware server. once both
        // the connections are properly initiated on both sides, we can
        // simply proxy the data raw between connections.
        var buffer = [UInt8](count: 8192, repeatedValue: 0)

        //first, we'll want the line of text identifying the protocol version from the client
        self.clientConnectionState = ConnectionState.WaitingForLine

        // enable async callbacks this new incoming socket
        self.clientInputStream = inputStream
        self.clientInputStream?.delegate = self
        inputStream.scheduleInRunLoop(.mainRunLoop(), forMode: NSDefaultRunLoopMode)
        self.clientOutputStream = outputStream

        // tell the client we support the "old" version of the vnc protocol
        // it's what the mac screen sharing client wants.
        let msg = [UInt8]("RFB 003.003\n".utf8)
        var size = outputStream.write(msg, maxLength: msg.count)
        if (size <= 0) {
            //XXX err
            return
        }
        
        waitForLineFromClient() { (line: String) -> Void in
            if line != "RFB 003.003\n" {
                //XXX err
                return
            }

            // the next thing we want is going to be variable length data
            self.clientConnectionState = ConnectionState.WaitingForData

            // send security type 0x00000002 (regular vnc password).
            // it's the only security type that the osx screen sharing
            // client can tolerate. we ignore the received password anyway.
            buffer[0] = 0x00
            buffer[1] = 0x00
            buffer[2] = 0x00
            buffer[3] = 0x02
            size = outputStream.write(buffer, maxLength: 4)
            if (size <= 0) {
                //XXX err
                return
            }
            
            // send a shared secret to encrypt the password with
            // (again we don't care, we don't really validate the
            // password)
            size = outputStream.write(buffer, maxLength: 16)
            if (size <= 0) {
                //XXX err
                return
            }

            self.waitForDataFromClient(16) { (data) in
                // client sends us the password (that we ignore)

                // tell client that the password is ok
                buffer[0] = 0x00
                buffer[1] = 0x00
                buffer[2] = 0x00
                buffer[3] = 0x00
                size = outputStream.write(buffer, maxLength: 4)
                if (size <= 0) {
                    //XXX err
                    return
                }
                
                self.waitForDataFromClient(1) { (data) in
                    // client tells us if it's ok to share the desktop (we ignore)

                    // ok, now we have to proxy the actual vnc stuff from the server
                    print("client is ready for video, proxying..")
                    self.clientConnectionState = ConnectionState.ProxyingVnc
                    self.negotiateMksSession() {
                        print("the vnc session has begun")
                    }
                }
            }
        }
    }

    
    func negotiateMksSession(callback: () -> Void) {
        // this was tricky to write. there is a fairly invovled
        // synchronous conversation that needs to happen with the
        // vmware authd server, yet swift/cocoa seem to encourage
        // an async pattern. i debated just doing a synchronous
        // conversation in a thread or a seperate gcd task, but ended
        // up doing it this way.
        //
        // the `waitFor...()` functions hide the async event handling
        // underneath and call the following lambda/blocks at the
        // appropriate times, as sort of a poor man's promise/future.
        //
        // writes are still blocking, but since the amount of data
        // being sent is so small, it ends up being buffered by the
        // underlying socket anyway, so it probably doesn't matter.
        //
        // i've annotated the conversation with `> ...` (client to server)
        // and `< ...` (server to client) to illustrate the conversation

        var readStream: Unmanaged<CFReadStreamRef>?
        var writeStream: Unmanaged<CFWriteStreamRef>?
        CFStreamCreatePairWithSocketToHost(nil, self.vmwareHost, UInt32(self.vmwarePort), &readStream, &writeStream);
        
        self.vmwInputStream = readStream!.takeRetainedValue()
        self.vmwInputStream?.delegate = self
        self.vmwInputStream?.scheduleInRunLoop(.mainRunLoop(), forMode: NSDefaultRunLoopMode)
        
        self.vmwOutputStream = writeStream!.takeRetainedValue()
        self.vmwOutputStream?.delegate = self
        //self.vmwOutputStream?.scheduleInRunLoop(.mainRunLoop(), forMode: NSDefaultRunLoopMode)
        
        //next, we want a full line of text from the server
        self.serverConnectionState = ConnectionState.WaitingForLine

        self.vmwInputStream?.open()
        self.vmwOutputStream?.open()
        
        self.waitForLineFromServer() { (line: String) -> Void in
            /*
             < 220 VMware Authentication Daemon Version 1.10: SSL Required, ServerDaemonProtocol:SOAP, MKSDisplayProtocol:VNC , VMXARGS supported, NFCSSL supported
             */

            if !line.hasPrefix("220 ") {
                //XXX err
                return
            }

            self.sslCtx = SSLCreateContext(kCFAllocatorDefault, SSLProtocolSide.ClientSide, SSLConnectionType.StreamType)
            guard let sslCtx = self.sslCtx else {
                fatalError("failed to create ssl ctx")
            }

            SSLSetSessionOption(sslCtx, SSLSessionOption.BreakOnServerAuth, true)
            SSLSetIOFuncs(sslCtx, sslReadCallback, sslWriteCallback)
            SSLSetConnection(sslCtx, self.selfPtr)
            
            //next we'll want a callback when any data is ready (to attempt ssl handshake)
            self.serverConnectionState = ConnectionState.WaitingForData
            self.waitForDataFromServer() { () -> Void in
                var r = SSLHandshake(sslCtx)
                if r == -9841 { //XXX we're supposed to verify the SSL cert here
                   r = SSLHandshake(sslCtx)
                }
                
                if r == -9803 {
                    return // would block, wait to try again
                } else if r != 0 {
                    // XXX err
                    return
                }

                //next, we'll want a line of text from the server
                self.serverConnectionState = ConnectionState.WaitingForLine
                
                /*
                 > USER 52cf8c64-9343-7cb7-d151-1bfc481bb7d5
                 */
                var written : Int = 0
                let loginMessage = "USER \(self.sessionTicket)\r\n".dataUsingEncoding(NSUTF8StringEncoding)

                r = SSLWrite(sslCtx, loginMessage!.bytes, loginMessage!.length, &written)
                if r != 0 {
                    // XXX err
                    return
                }

                self.waitForLineFromServer() { (line: String) -> Void in
                    /*
                     < 331 Password required for 52cf8c64-9343-7cb7-d151-1bfc481bb7d5.
                     */
                    if !line.hasPrefix("331 ") {
                        //XXX err
                        return
                    }
                    /*
                     > PASS 52cf8c64-9343-7cb7-d151-1bfc481bb7d5
                     */
                    
                    let passMessage = "PASS \(self.sessionTicket)\r\n".dataUsingEncoding(NSUTF8StringEncoding)
                    r = SSLWrite(sslCtx, passMessage!.bytes, passMessage!.length, &written)
                    if r != 0 {
                        // XXX err
                        return
                    }

                    self.waitForLineFromServer() { (line: String) -> Void in
                        /*
                         < 230 User 52cf8c64-9343-7cb7-d151-1bfc481bb7d5 logged in.
                         */
                        if !line.hasPrefix("230 ") {
                            //XXX err
                            return
                        }
                    
                        /*
                         > THUMBPRINT <b64 encode 12 random bytes>
                         */
                        let randomData = NSMutableData(length: 12)!
                        let err = SecRandomCopyBytes(kSecRandomDefault, 12, UnsafeMutablePointer<UInt8>(randomData.mutableBytes));
                        if (err != 0) {
                            fatalError("failed to generate random bytes")
                        }
                        let randomDataStr = randomData.base64EncodedStringWithOptions(NSDataBase64EncodingOptions.Encoding76CharacterLineLength)
                        
                        let thumbprintMessage = "THUMBPRINT \(randomDataStr)\r\n".dataUsingEncoding(NSUTF8StringEncoding)
                        r = SSLWrite(sslCtx, thumbprintMessage!.bytes, thumbprintMessage!.length, &written)
                        if r != 0 {
                            // XXX err
                            return
                        }
                        
                        self.waitForLineFromServer() { (line: String) -> Void in
                            /*
                             < 200 C5:50:62:9F:97:1D:AF:96:91:0B:2D:0E:2A:CA:2E:52:FB:60:87:73
                             */
                            if !line.hasPrefix("200 ") {
                                //XXX err
                                return
                            }
                    
                            /*
                             > CONNECT <vmfs path> mks\r\n
                             */
                            let connectMessage = "CONNECT \(self.vmCfgFile) mks\r\n".dataUsingEncoding(NSUTF8StringEncoding)
                            r = SSLWrite(sslCtx, connectMessage!.bytes, connectMessage!.length, &written)
                            if r != 0 {
                                // XXX err
                                return
                            }

                            self.waitForLineFromServer() { (line: String) -> Void in
                                /*
                                 < 200 Connect /vmfs/volumes/56d5c29a-ac1ca31f-fd75-089e01d8b64c/scottjg-enterprise2-test/scottjg-enterprise2-test.vmx
                                 */
                                if !line.hasPrefix("200 ") {
                                    //XXX err
                                    return
                                }
                                
                                // this is weird but at this point in the protocol we have to redo the ssl handshake
                                self.sslCtx = SSLCreateContext(kCFAllocatorDefault, SSLProtocolSide.ClientSide, SSLConnectionType.StreamType)
                                guard let sslCtx = self.sslCtx else {
                                    fatalError("failed to create second ssl ctx")
                                }
                                SSLSetSessionOption(sslCtx, SSLSessionOption.BreakOnServerAuth, true)
                                SSLSetIOFuncs(sslCtx, sslReadCallback, sslWriteCallback)
                                SSLSetConnection(sslCtx, self.selfPtr)

                                //next we'll want a callback for any ready data, to continue the handshake
                                self.serverConnectionState = ConnectionState.WaitingForData

                                self.waitForDataFromServer() { () -> Void in
                                    var r = SSLHandshake(sslCtx)
                                    if r == -9841 { //XXX we're supposed to verify the SSL cert here
                                        r = SSLHandshake(sslCtx)
                                    }
                                    
                                    if r == -9803 {
                                        return // would block, wait to try again
                                    } else if r != 0 {
                                        // XXX err
                                        return
                                    }

                                    // after we send this last message, we start to prepare to proxy the vnc data
                                    self.serverConnectionState = ConnectionState.ProxyingVnc
                                    
                                    let randomDataStrData = randomDataStr.dataUsingEncoding(NSUTF8StringEncoding)!
                                    r = SSLWrite(self.sslCtx!, randomDataStrData.bytes, randomDataStrData.length, &written)
                                    if r != 0 {
                                        // XXX err
                                        return
                                    }
                                    
                                    callback()
                                }
                            }
                        }
                    }
                }
            }
        }
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
        if (r != CFSocketError.Success) {
            fatalError("failed to set socket addr")
        }
        
        var addrLen = socklen_t(sizeofValue(addr))
        withUnsafeMutablePointers(&addr, &addrLen) { (sinPtr, addrPtr) -> Int32 in
            getsockname(fd, UnsafeMutablePointer(sinPtr), UnsafeMutablePointer(addrPtr))
        }
        let port = addr.sin_port.bigEndian
        print("assigned port \(port)")
        
        
        self.vncServerSocketEventSource = CFSocketCreateRunLoopSource(
            kCFAllocatorDefault,
            self.vncServerSocket,
            0);
        
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            self.vncServerSocketEventSource,
            kCFRunLoopDefaultMode);
        
        print("waiting for incoming connection...")
        return port
    }

    // --- everything below here is just plumbing to implement the
    // --- async stuff for the `waitingFor...()` functions and the inner
    // --- loop for proxying the raw vnc connection once the session has
    // --- fully started. it's pretty gross, not very efficient, and could
    // --- use a lot of cleanup. might be worth pulling out into a separate
    // --- class (should i have just used AsyncSocket???). that said, i'm
    // --- just leaving it right now since it's working.
    
    enum ConnectionState {
        case Unknown
        case WaitingForLine
        case WaitingForData
        case ProxyingVnc
    }
    
    var serverConnectionState: ConnectionState = ConnectionState.Unknown
    var serverLineSoFar = NSMutableData()
    var serverHaveFullLine = false
    var serverLineWaitingCallback: ((line: String) -> Void)? = nil

    func waitForLineFromServer(callback: (line: String) -> Void) {
        assert(self.serverConnectionState == ConnectionState.WaitingForLine)
        self.serverLineWaitingCallback = callback
        self.stream(self.vmwInputStream!, handleEvent: NSStreamEvent.HasBytesAvailable)
    }

    var dataWaitingServerCallback: (() -> Void)? = nil
    func waitForDataFromServer(callback: () -> Void) {
        assert(self.serverConnectionState == ConnectionState.WaitingForData)
        self.dataWaitingServerCallback = callback
        self.stream(self.vmwInputStream!, handleEvent: NSStreamEvent.HasBytesAvailable)
    }

    
    var clientConnectionState: ConnectionState = ConnectionState.Unknown
    var clientLineSoFar = NSMutableData()
    var clientHaveFullLine = false
    var clientLineWaitingCallback: ((line: String) -> Void)? = nil
    
    func waitForLineFromClient(callback: (line: String) -> Void) {
        assert(self.clientConnectionState == ConnectionState.WaitingForLine)
        self.clientLineWaitingCallback = callback
        self.stream(self.clientInputStream!, handleEvent: NSStreamEvent.HasBytesAvailable)
    }
    
    var clientDataWaitingCallback: ((data: NSData) -> Void)? = nil
    var clientDataWaitingSize = 0
    func waitForDataFromClient(size: Int, callback: (data: NSData) -> Void) {
        assert(self.clientConnectionState == ConnectionState.WaitingForData)
        self.clientDataWaitingCallback = callback
        self.clientDataWaitingSize = size
        self.stream(self.clientInputStream!, handleEvent: NSStreamEvent.HasBytesAvailable)
    }
    
    func stream(aStream: NSStream, handleEvent eventCode: NSStreamEvent) {
        var buffer = [UInt8](count: 8192, repeatedValue: 0)
        if aStream == self.vmwInputStream {
            guard let inputStream = self.vmwInputStream else {
                return
            }
            switch self.serverConnectionState {
            case ConnectionState.WaitingForLine:
                // XXX note this is only expecting a single line at a time from the server between responses
                while (!self.serverHaveFullLine && self.serverLineWaitingCallback != nil) || inputStream.hasBytesAvailable {
                    while inputStream.hasBytesAvailable && !self.serverHaveFullLine {
                        var readSize: Int = 0
                        if let sslCtx = self.sslCtx {
                            let r = SSLRead(sslCtx, &buffer, buffer.count, &readSize)
                            if readSize <= 0 {
                                if r == errSSLWouldBlock {
                                    continue
                                } else {
                                    print("server disconnected")
                                    self.cleanup(false)
                                    return
                                }
                            }
                        } else {
                            readSize = inputStream.read(&buffer, maxLength: buffer.count)
                            if readSize <= 0 {
                                //something bad is happening
                            }
                        }

                        self.serverLineSoFar.appendBytes(buffer, length: readSize)
                        if buffer[readSize - 1] == 0x0a { //newline
                            self.serverHaveFullLine = true
                        }
                    }

                    if self.serverHaveFullLine && self.serverLineWaitingCallback != nil {
                        let line = String(data: self.serverLineSoFar, encoding: NSUTF8StringEncoding)!
                        let callback = self.serverLineWaitingCallback!

                        self.serverLineWaitingCallback = nil
                        self.serverLineSoFar = NSMutableData()
                        self.serverHaveFullLine = false

                        callback(line: line)

                    }
                }
                break
            case ConnectionState.WaitingForData:
                self.dataWaitingServerCallback!()
                break
            case ConnectionState.ProxyingVnc:
                proxyVnc()
                break
            default:
                fatalError("unknown connection state")
            }
        } else if aStream == self.clientInputStream {
            guard let inputStream = self.clientInputStream else {
                return
            }
            switch self.clientConnectionState {
            case ConnectionState.WaitingForLine:
                // XXX note this is only expecting a single line at a time from the client between responses
                while (!self.clientHaveFullLine && self.clientLineWaitingCallback != nil) || inputStream.hasBytesAvailable {
                    while inputStream.hasBytesAvailable && !self.clientHaveFullLine {
                        let readSize = inputStream.read(&buffer, maxLength: buffer.count)
                        if readSize <= 0 {
                            //something bad is happening
                            //XXX err
                            return
                        }
                        
                        self.clientLineSoFar.appendBytes(buffer, length: readSize)
                        if buffer[readSize - 1] == 0x0a { //newline
                            self.clientHaveFullLine = true
                        }
                    }
                    
                    if self.clientHaveFullLine && self.clientLineWaitingCallback != nil {
                        let line = String(data: self.clientLineSoFar, encoding: NSUTF8StringEncoding)!
                        let callback = self.clientLineWaitingCallback!
                        
                        self.clientLineWaitingCallback = nil
                        self.clientLineSoFar = NSMutableData()
                        self.clientHaveFullLine = false
                        
                        callback(line: line)
                        
                    }
                }
                break
            case ConnectionState.WaitingForData:
                // XXX note this is only expecting a single line at a time from the client between responses
                while inputStream.hasBytesAvailable || (self.clientDataWaitingSize == 0 && self.clientDataWaitingCallback != nil) {
                    while self.clientDataWaitingSize > 0 && inputStream.hasBytesAvailable {
                        let readSize = inputStream.read(&buffer, maxLength: self.clientDataWaitingSize)
                        if readSize <= 0 {
                            //something bad is happening
                            //XXX err
                            inputStream.close()
                            if let outputStream = self.clientOutputStream {
                                outputStream.close()
                            }
                            print("client disconnected")
                            return
                        }
                        self.clientDataWaitingSize -= readSize
                        self.clientLineSoFar.appendBytes(buffer, length: readSize)
                    }

                    if self.clientDataWaitingSize == 0 && self.clientDataWaitingCallback != nil {
                        let data = self.clientLineSoFar
                        let callback = self.clientDataWaitingCallback!

                        self.clientLineSoFar = NSMutableData()
                        self.clientDataWaitingCallback = nil
                        callback(data: data)
                    }
                }
                break
            case ConnectionState.ProxyingVnc:
                proxyVnc()
                break
            default:
                fatalError("unknown connection state")
            }
        }

    }
    
    var lastActiveTime = NSDate()
    
    func proxyVnc() {
        var idle = false
        //print("vmwinputstream event!")
        if self.clientOutputStream == nil {
            print("not ready!")
            return
        }
        
        if let inputStream = self.vmwInputStream {
            if inputStream.hasBytesAvailable {
                while true {
                    var buffer = [UInt8](count: 32768, repeatedValue: 0)
                    var readSize : Int = 0
                    let r = SSLRead(self.sslCtx!, &buffer, buffer.count, &readSize)
                    //print ("vmw read: \(readSize): \(buffer[0]) \(buffer[1])")
                    //print("r=\(r), readsize=\(readSize)")
                    //assert(readSize > 0)
                    if readSize <= 0 {
                        if r == errSSLWouldBlock {
                            break
                        }
                        print("server disconnected")
                        self.cleanup(false)
                        return
                    }
                
                    let written = self.clientOutputStream?.write(buffer, maxLength: readSize)
                    assert(written == readSize)
                    idle = true
                }
            }
        }
        
        if let inputStream = self.clientInputStream {
            while inputStream.hasBytesAvailable {
                var buffer = [UInt8](count: 32768, repeatedValue: 0)
                let readSize = self.clientInputStream?.read(&buffer, maxLength: buffer.count)
                //print ("client read: \(readSize)")
                //assert(readSize > 0)
                if readSize <= 0 {
                    print("client disconnected")
                    self.cleanup(true)
                    return
                }
                
                var written : Int = 0
                SSLWrite(self.sslCtx!, buffer, readSize!, &written)
                assert(written == readSize!)
                idle = true
            }
        }
        
        if !idle {
            lastActiveTime = NSDate()
        }
    }

    func cleanup(closeServer: Bool) {
        if let sslCtx = self.sslCtx {
            SSLClose(sslCtx)
            self.sslCtx = nil
        }

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
        
        self.serverLineWaitingCallback = nil
        self.dataWaitingServerCallback = nil
        self.clientLineWaitingCallback = nil
        self.clientDataWaitingCallback = nil
        self.clientConnectionState = ConnectionState.Unknown
        self.serverConnectionState = ConnectionState.Unknown

        let idleTimeInterval = lastActiveTime.timeIntervalSinceNow
        if idleTimeInterval < -5 || closeServer {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                self.vncServerSocketEventSource,
                kCFRunLoopDefaultMode);

            let fd = CFSocketGetNative(self.vncServerSocket)
            close(fd)
            
            self.vncServerSocketEventSource = nil
            self.vncServerSocket = nil
        }
    }
}

func acceptVncClientConnection(s: CFSocket!, callbackType: CFSocketCallBackType, address: CFData!, data: UnsafePointer<Void>, info: UnsafeMutablePointer<Void>) {
    let delegate = UnsafeMutablePointer<VMwareMksVncProxy>(info).memory
    
    //let sockAddr = UnsafePointer<sockaddr_in>(CFDataGetBytePtr(address))
    //let ipAddress = inet_ntoa(sockAddr.memory.sin_addr)
    //let addrData = NSData(bytes: ipAddress, length: Int(INET_ADDRSTRLEN))
    //let ipAddressStr = NSString(data: addrData, encoding: NSUTF8StringEncoding)!
    //print("Received a connection from \(ipAddressStr)")
    
    let clientSocketHandle = UnsafePointer<CFSocketNativeHandle>(data).memory
    
    var readStream : Unmanaged<CFReadStream>?
    var writeStream : Unmanaged<CFWriteStream>?
    CFStreamCreatePairWithSocket(kCFAllocatorDefault, clientSocketHandle, &readStream, &writeStream)
    delegate.vncClientSocketFd = clientSocketHandle
    
    let inputStream: NSInputStream = readStream!.takeRetainedValue()
    let outputStream: NSOutputStream = writeStream!.takeRetainedValue()
    
    inputStream.open()
    outputStream.open()
    
    delegate.handleVncProxyClient(inputStream, outputStream: outputStream)
}

func sslReadCallback(connection: SSLConnectionRef,
                     data: UnsafeMutablePointer<Void>,
                     dataLength: UnsafeMutablePointer<Int>) -> OSStatus {
    let delegate = UnsafeMutablePointer<VMwareMksVncProxy>(connection).memory
    let inputStream = delegate.vmwInputStream!
    let expectedReadSize = dataLength.memory
    dataLength.memory = 0
    //print("starting ssl read callback, expecting \(expectedReadSize) bytes")
    if inputStream.hasBytesAvailable && dataLength.memory < expectedReadSize {
        let size = inputStream.read(UnsafeMutablePointer<UInt8>(data), maxLength: expectedReadSize)
        //print("expectedReadSize=\(expectedReadSize), actual read size=\(size)")
        if (size == 0) {
            //print("ssl read closed")
            return Int32(errSSLClosedGraceful)
        }
        dataLength.memory += size
    }

    if (dataLength.memory < expectedReadSize) {
        //print("would have blocked. read \(dataLength.memory) of \(expectedReadSize)")
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

//
//  VMwareMksVncProxy.swift
//  esxclient
//
//  Copyright © 2016 scottjg. All rights reserved.
//

import CoreFoundation
import Foundation
import Cocoa
fileprivate func < <T : Comparable>(lhs: T?, rhs: T?) -> Bool {
  switch (lhs, rhs) {
  case let (l?, r?):
    return l < r
  case (nil, _?):
    return true
  default:
    return false
  }
}

fileprivate func <= <T : Comparable>(lhs: T?, rhs: T?) -> Bool {
  switch (lhs, rhs) {
  case let (l?, r?):
    return l <= r
  default:
    return !(rhs < lhs)
  }
}


class VMwareMksVncProxy : NSObject, StreamDelegate {
    var vmwareHost, sessionTicket, vmCfgFile, vmwareSslThumbprint : String
    var vmwarePort : UInt16
    
    var vmwInputStream: InputStream?
    var vmwOutputStream: OutputStream?
    var vmwSocket: SyncSocket?
    var clientInputStream: InputStream?
    var clientOutputStream: OutputStream?
    var sslCtx: SSLContext?
    
    var vncServerSocket : CFSocket?
    var vncServerSocketEventSource: CFRunLoopSource? = nil
    var vncClientSocketFd: CFSocketNativeHandle = -1
    
    var selfPtr: UnsafeMutablePointer<VMwareMksVncProxy>? = nil
    
    init(host: String, ticket: String, cfgFile: String, port: UInt16, sslThumbprint: String) {
        self.vmwareHost = host
        self.vmwarePort = port
        self.sessionTicket = ticket
        self.vmCfgFile = cfgFile
        self.vmwareSslThumbprint = sslThumbprint

        super.init()

        self.selfPtr = UnsafeMutablePointer<VMwareMksVncProxy>.allocate(capacity: 1)
        selfPtr?.initialize(to: self)
    }
    
    deinit {
        selfPtr?.deallocate(capacity: 1)
    }

    func setupVncProxyServerPort(_ callback: (_ port: UInt16) -> Void) {
        // setup a random port to listen for a vnc client
        let port = self.startVncProxyServer()

        // tell the application that the port is ready
        // (and to presumably start the vnc client)
        callback(port)
    }

    func handleVncProxyClient(_ inputStream : InputStream, outputStream : OutputStream) {
        // this runs when the vnc client connects to our proxy port.
        // the vmware mks protocol is similar to vnc, but it starts
        // slightly different. so we pretend to be the vnc server at
        // the beginning to get the client ready, while also pretending
        // to be a vmware mks client to the vmware server. once both
        // the connections are properly initiated on both sides, we can
        // simply proxy the data raw between connections.

        //first, we'll want the line of text identifying the protocol version from the client
        //self.clientConnectionState = ConnectionState.waitingForLine

        // enable async callbacks this new incoming socket
        //self.clientInputStream = inputStream
        //self.clientInputStream?.delegate = self
        //inputStream.schedule(in: .main, forMode: RunLoopMode.defaultRunLoopMode)
        //self.clientOutputStream = outputStream
        let clientSocket = SyncSocket(inputStream: inputStream, outputStream: outputStream)
        
        // tell the client we support the "old" version of the vnc protocol
        // it's what the mac screen sharing client wants.
        let msg = [UInt8]("RFB 003.003\n".utf8)
        try! clientSocket.write(msg)

        let line = try! clientSocket.readLine(16)
        if line != "RFB 003.003" {
            //XXX err
            return
        }

        // send security type 0x00000002 (regular vnc password).
        // it's the only security type that the osx screen sharing
        // client can tolerate. we ignore the received password anyway.
        var cmd = [UInt8](repeating: 0, count: 4)
        cmd[0] = 0x00
        cmd[1] = 0x00
        cmd[2] = 0x00
        cmd[3] = 0x02
        try! clientSocket.write(cmd)
        
        // send a shared secret to encrypt the password with
        // (again we don't care, we don't really validate the
        // password)
        var secret = [UInt8](repeating: 0, count: 16)
        secret[0 ] = 0x01
        secret[1 ] = 0x02
        secret[2 ] = 0x03
        secret[3 ] = 0x04
        secret[4 ] = 0x05
        secret[5 ] = 0x06
        secret[6 ] = 0x07
        secret[7 ] = 0x08
        secret[8 ] = 0x09
        secret[9 ] = 0x0A
        secret[10] = 0x0B
        secret[11] = 0x0C
        secret[12] = 0x0D
        secret[13] = 0x0E
        secret[14] = 0x0F
        secret[15] = 0x10
        try! clientSocket.write(secret)

        // client sends us the password (that we ignore)
        _ = try! clientSocket.read(16)
        
        // tell client that the password is ok
        cmd[0] = 0x00
        cmd[1] = 0x00
        cmd[2] = 0x00
        cmd[3] = 0x00
        try! clientSocket.write(cmd)
        
        _ = try! clientSocket.read(1)
        // client tells us if it's ok to share the desktop (we ignore)

        // ok, now we have to proxy the actual vnc stuff from the server
        print("client is ready for video, proxying..")
        self.clientConnectionState = ConnectionState.proxyingVnc
        self.negotiateMksSession() {
            print("the vnc session has begun")
            let proxy = SyncSocketProxy(socket1: self.vmwSocket!, socket2: clientSocket)
            proxy.proxyUntilHangup()
        }
    }

    
    func negotiateMksSession(_ callback: @escaping () -> Void) {
        let vmwSocket = SyncSocket(host: self.vmwareHost, port: self.vmwarePort)
        self.vmwSocket = vmwSocket
        do {
            try vmwSocket.connect()
            
            var line = try vmwSocket.readLine(nil)
            /*
             < 220 VMware Authentication Daemon Version 1.10: SSL Required, ServerDaemonProtocol:SOAP, MKSDisplayProtocol:VNC , VMXARGS supported, NFCSSL supported
             */
            
            if !line.hasPrefix("220 ") {
                //XXX err
                return
            }

            try vmwSocket.startSSL()
            
            try vmwSocket.write("USER \(self.sessionTicket)\r\n")

            /*
             < 331 Password required for 52cf8c64-9343-7cb7-d151-1bfc481bb7d5.
             */
            line = try vmwSocket.readLine(nil)
            if !line.hasPrefix("331 ") {
                //XXX err
                return
            }
            /*
             > PASS 52cf8c64-9343-7cb7-d151-1bfc481bb7d5
             */
            
            try vmwSocket.write("PASS \(self.sessionTicket)\r\n")

            
            /*
             < 230 User 52cf8c64-9343-7cb7-d151-1bfc481bb7d5 logged in.
             */
            line = try vmwSocket.readLine(nil)
            if !line.hasPrefix("230 ") {
                //XXX err
                return
            }
            
            /*
             > THUMBPRINT <b64 encode 12 random bytes>
             */
            var randomData = Data(count: 12)
            let err = randomData.withUnsafeMutableBytes {mutableBytes in
                SecRandomCopyBytes(kSecRandomDefault, 12, mutableBytes)
            }
            if (err != 0) {
                fatalError("failed to generate random bytes")
            }
            let randomDataStr = randomData.base64EncodedString(options: NSData.Base64EncodingOptions.lineLength76Characters)
            
            try vmwSocket.write("THUMBPRINT \(randomDataStr)\r\n")
            
            /*
             < 200 C5:50:62:9F:97:1D:AF:96:91:0B:2D:0E:2A:CA:2E:52:FB:60:87:73
             */
            line = try vmwSocket.readLine(nil)
            if !line.hasPrefix("200 ") {
                //XXX err
                return
            }
                
            /*
             > CONNECT <vmfs path> mks\r\n
             */
            try vmwSocket.write("CONNECT \(self.vmCfgFile) mks\r\n")
            
            /*
             < 200 Connect /vmfs/volumes/56d5c29a-ac1ca31f-fd75-089e01d8b64c/scottjg-enterprise2-test/scottjg-enterprise2-test.vmx
             */
            line = try vmwSocket.readLine(nil)
            if !line.hasPrefix("200 ") {
                //XXX err
                return
            }
                    

            try vmwSocket.startSSL()

            self.serverConnectionState = ConnectionState.proxyingVnc
            try vmwSocket.write(randomDataStr)
            callback()
        } catch let err as NSError {
            print(err)
        }
    }
    

    func startVncProxyServer() -> UInt16 {
        var socketContext = CFSocketContext()
        socketContext.info = UnsafeMutableRawPointer(selfPtr)
        
        self.vncServerSocket = CFSocketCreate(kCFAllocatorDefault, PF_INET, SOCK_STREAM, IPPROTO_TCP, CFSocketCallBackType.acceptCallBack.rawValue, acceptVncClientConnection, &socketContext)
        
        let fd = CFSocketGetNative(self.vncServerSocket)
        var reuse = true
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        
        var addr = sockaddr_in(sin_len: 0, sin_family: 0, sin_port: 0, sin_addr: in_addr(s_addr: 0), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        addr.sin_len = UInt8(MemoryLayout.size(ofValue: addr))
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = UInt32(0x7F000001).bigEndian
        //addr.sin_port = UInt16(12345).bigEndian

        let data = NSData(bytes: &addr, length: MemoryLayout<sockaddr_in>.size) as CFData
        let r = CFSocketSetAddress(self.vncServerSocket, data)
        if (r != CFSocketError.success) {
            fatalError("failed to set socket addr")
        }
        
        var addrLen = socklen_t(MemoryLayout.size(ofValue: addr))
        _ = withUnsafeMutablePointer(to: &addr) { (ptr) -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &addrLen)
            }
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
            CFRunLoopMode.defaultMode);
        
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
        case unknown
        case waitingForLine
        case waitingForData
        case proxyingVnc
    }
    
    var serverConnectionState: ConnectionState = ConnectionState.unknown
    var serverLineSoFar = NSMutableData()
    var serverHaveFullLine = false
    var serverLineWaitingCallback: ((_ line: String) -> Void)? = nil

    func waitForLineFromServer(_ callback: @escaping (_ line: String) -> Void) {
        assert(self.serverConnectionState == ConnectionState.waitingForLine)
        self.serverLineWaitingCallback = callback
        self.stream(self.vmwInputStream!, handle: Stream.Event.hasBytesAvailable)
    }

    var dataWaitingServerCallback: (() -> Void)? = nil
    func waitForDataFromServer(_ callback: @escaping () -> Void) {
        assert(self.serverConnectionState == ConnectionState.waitingForData)
        self.dataWaitingServerCallback = callback
        self.stream(self.vmwInputStream!, handle: Stream.Event.hasBytesAvailable)
    }

    
    var clientConnectionState: ConnectionState = ConnectionState.unknown
    var clientLineSoFar = NSMutableData()
    var clientHaveFullLine = false
    var clientLineWaitingCallback: ((_ line: String) -> Void)? = nil
    
    func waitForLineFromClient(_ callback: @escaping (_ line: String) -> Void) {
        assert(self.clientConnectionState == ConnectionState.waitingForLine)
        self.clientLineWaitingCallback = callback
        self.stream(self.clientInputStream!, handle: Stream.Event.hasBytesAvailable)
    }
    
    var clientDataWaitingCallback: ((_ data: Data) -> Void)? = nil
    var clientDataWaitingSize = 0
    func waitForDataFromClient(_ size: Int, callback: @escaping (_ data: Data) -> Void) {
        assert(self.clientConnectionState == ConnectionState.waitingForData)
        self.clientDataWaitingCallback = callback
        self.clientDataWaitingSize = size
        self.stream(self.clientInputStream!, handle: Stream.Event.hasBytesAvailable)
    }
    
    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        var buffer = [UInt8](repeating: 0, count: 8192)
        if aStream == self.vmwInputStream {
            guard let inputStream = self.vmwInputStream else {
                return
            }
            switch self.serverConnectionState {
            case ConnectionState.waitingForLine:
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

                        self.serverLineSoFar.append(buffer, length: readSize)
                        if buffer[readSize - 1] == 0x0a { //newline
                            self.serverHaveFullLine = true
                        }
                    }

                    if self.serverHaveFullLine && self.serverLineWaitingCallback != nil {
                        let line = String(data: self.serverLineSoFar as Data, encoding: String.Encoding.utf8)!
                        let callback = self.serverLineWaitingCallback!

                        self.serverLineWaitingCallback = nil
                        self.serverLineSoFar = NSMutableData()
                        self.serverHaveFullLine = false

                        callback(line)

                    }
                }
                break
            case ConnectionState.waitingForData:
                self.dataWaitingServerCallback!()
                break
            case ConnectionState.proxyingVnc:
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
            case ConnectionState.waitingForLine:
                // XXX note this is only expecting a single line at a time from the client between responses
                while (!self.clientHaveFullLine && self.clientLineWaitingCallback != nil) || inputStream.hasBytesAvailable {
                    while inputStream.hasBytesAvailable && !self.clientHaveFullLine {
                        let readSize = inputStream.read(&buffer, maxLength: buffer.count)
                        if readSize <= 0 {
                            //something bad is happening
                            //XXX err
                            return
                        }
                        
                        self.clientLineSoFar.append(buffer, length: readSize)
                        if buffer[readSize - 1] == 0x0a { //newline
                            self.clientHaveFullLine = true
                        }
                    }
                    
                    if self.clientHaveFullLine && self.clientLineWaitingCallback != nil {
                        let line = String(data: self.clientLineSoFar as Data, encoding: String.Encoding.utf8)!
                        let callback = self.clientLineWaitingCallback!
                        
                        self.clientLineWaitingCallback = nil
                        self.clientLineSoFar = NSMutableData()
                        self.clientHaveFullLine = false
                        
                        callback(line)
                        
                    }
                }
                break
            case ConnectionState.waitingForData:
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
                        self.clientLineSoFar.append(buffer, length: readSize)
                    }

                    if self.clientDataWaitingSize == 0 && self.clientDataWaitingCallback != nil {
                        let data = self.clientLineSoFar
                        let callback = self.clientDataWaitingCallback!

                        self.clientLineSoFar = NSMutableData()
                        self.clientDataWaitingCallback = nil
                        callback(data as Data)
                    }
                }
                break
            case ConnectionState.proxyingVnc:
                proxyVnc()
                break
            default:
                fatalError("unknown connection state")
            }
        }

    }
    
    var lastActiveTime = Date()
    
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
                    var buffer = [UInt8](repeating: 0, count: 32768)
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
                var buffer = [UInt8](repeating: 0, count: 32768)
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
            lastActiveTime = Date()
        }
    }

    func cleanup(_ closeServer: Bool) {
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
        self.clientConnectionState = ConnectionState.unknown
        self.serverConnectionState = ConnectionState.unknown

        let idleTimeInterval = lastActiveTime.timeIntervalSinceNow
        if idleTimeInterval < -5 || closeServer {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                self.vncServerSocketEventSource,
                CFRunLoopMode.defaultMode);

            let fd = CFSocketGetNative(self.vncServerSocket)
            close(fd)
            
            self.vncServerSocketEventSource = nil
            self.vncServerSocket = nil
        }
    }
}

func acceptVncClientConnection(_ s: CFSocket?, callbackType: CFSocketCallBackType, address: CFData?, data: UnsafeRawPointer?, info: UnsafeMutableRawPointer?) {
    let delegate = info!.assumingMemoryBound(to: VMwareMksVncProxy.self).pointee
    
    //let delegate = info.withMemoryRebound(to: VMwareMksVncProxy.self, capacity: 1) {
    //        $0.pointee
    //}
    
    //let sockAddr = UnsafePointer<sockaddr_in>(CFDataGetBytePtr(address))
    //let ipAddress = inet_ntoa(sockAddr.memory.sin_addr)
    //let addrData = NSData(bytes: ipAddress, length: Int(INET_ADDRSTRLEN))
    //let ipAddressStr = NSString(data: addrData, encoding: NSUTF8StringEncoding)!
    //print("Received a connection from \(ipAddressStr)")
    
    let clientSocketHandle = data!.assumingMemoryBound(to: CFSocketNativeHandle.self).pointee
    
    var readStream : Unmanaged<CFReadStream>?
    var writeStream : Unmanaged<CFWriteStream>?
    CFStreamCreatePairWithSocket(kCFAllocatorDefault, clientSocketHandle, &readStream, &writeStream)
    delegate.vncClientSocketFd = clientSocketHandle
    
    let inputStream: InputStream = readStream!.takeRetainedValue()
    let outputStream: OutputStream = writeStream!.takeRetainedValue()
    
    inputStream.open()
    outputStream.open()
    
    delegate.handleVncProxyClient(inputStream, outputStream: outputStream)
}

func sslReadCallback(_ connection: SSLConnectionRef,
                     data: UnsafeMutableRawPointer,
                     dataLength: UnsafeMutablePointer<Int>) -> OSStatus {
    let delegate = connection.assumingMemoryBound(to: VMwareMksVncProxy.self).pointee
    let inputStream = delegate.vmwInputStream!
    let expectedReadSize = dataLength.pointee
    dataLength.pointee = 0
    //print("starting ssl read callback, expecting \(expectedReadSize) bytes")
    if inputStream.hasBytesAvailable && dataLength.pointee < expectedReadSize {
        let size = inputStream.read(data.assumingMemoryBound(to: UInt8.self), maxLength: expectedReadSize)
        //print("expectedReadSize=\(expectedReadSize), actual read size=\(size)")
        if (size == 0) {
            //print("ssl read closed")
            return Int32(errSSLClosedGraceful)
        }
        dataLength.pointee += size
    }

    if (dataLength.pointee < expectedReadSize) {
        //print("would have blocked. read \(dataLength.memory) of \(expectedReadSize)")
        return Int32(errSSLWouldBlock)
    }
    
    return 0
}

func sslWriteCallback(_ connection: SSLConnectionRef,
                      data: UnsafeRawPointer,
                      dataLength: UnsafeMutablePointer<Int>) -> OSStatus {
    let delegate = connection.assumingMemoryBound(to: VMwareMksVncProxy.self).pointee
    let outputStream = delegate.vmwOutputStream!
    
    outputStream.write(data.assumingMemoryBound(to: UInt8.self), maxLength: dataLength.pointee)
    return 0
}

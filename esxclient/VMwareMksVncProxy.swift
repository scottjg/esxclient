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

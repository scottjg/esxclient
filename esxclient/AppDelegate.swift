//
//  AppDelegate.swift
//  esxclient
//
//  Created by Scott Goldman on 4/7/16.
//  Copyright © 2016 scottjg. All rights reserved.
//

import Cocoa

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate, NSStreamDelegate {

    @IBOutlet weak var window: NSWindow!
    var vmwInputStream: NSInputStream?
    var vmwOutputStream: NSOutputStream?
    var clientInputStream: NSInputStream?
    var clientOutputStream: NSOutputStream?
    
    var sslCtx: SSLContext?
    var sslSocketPair: (NSInputStream?, NSOutputStream?)
    
    var server: String
    var serverURL: NSURL
    var username: String
    var password: String
    var vmId: String
    
    var httpSession: NSURLSession
    
    enum ServerType { case Unknown, Host, Cluster }
    var serverType : ServerType
    var apiVersion : String
    
    var sessionManagerName : String
    var sessionKey : String
    
    override init() {
        username = "root"
        password = "passworD1"
        vmId = "114"
        server = "172.16.21.33"
        serverURL = NSURL(string: "https://\(server)/sdk")!

        httpSession = NSURLSession(configuration: NSURLSession.sharedSession().configuration, delegate: NSURLSessionDelegator(), delegateQueue: NSURLSession.sharedSession().delegateQueue)
        serverType = ServerType.Unknown
        apiVersion = ""
        sessionManagerName = ""
        sessionKey = ""
    }
    
    func applicationDidFinishLaunching(aNotification: NSNotification) {
        // Insert code here to initialize your application
        startConnection()
    }

    func applicationWillTerminate(aNotification: NSNotification) {
        // Insert code here to tear down your application
    }
    
    func startConnection() {
        let urlRequest = NSMutableURLRequest(URL: serverURL)
        urlRequest.HTTPMethod = "POST"
        urlRequest.HTTPBody = "<env:Envelope xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\" xmlns:env=\"http://schemas.xmlsoap.org/soap/envelope/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\"><env:Body><RetrieveServiceContent xmlns=\"urn:vim25\"><_this type=\"ServiceInstance\">ServiceInstance</_this></RetrieveServiceContent></env:Body></env:Envelope>".dataUsingEncoding(NSUTF8StringEncoding)
        
        httpSession.dataTaskWithRequest(urlRequest) { (data, response, error) -> Void in
            let xml = try! NSXMLDocument(data: data!, options: 0)
            let apiVersionNode = try! xml.nodesForXPath("//*[name()='apiVersion']")
            let apiVersion = apiVersionNode[0].stringValue!
            
            let apiTypeNode = try! xml.nodesForXPath("//*[name()='apiType']")
            let apiType = apiTypeNode[0].stringValue!
            
            print("api version is \(apiVersion) / \(apiType)")
            self.apiVersion = apiVersion
            if apiType == "HostAgent" {
                self.serverType = ServerType.Host
            }

            let sessionManagerNode = try! xml.nodesForXPath("//*[name()='sessionManager']")
            self.sessionManagerName = sessionManagerNode[0].stringValue!
            
            self.login()
        }.resume()
    }

    
    func login() {
        let urlRequest = NSMutableURLRequest(URL: serverURL)
        urlRequest.HTTPMethod = "POST"
        urlRequest.HTTPBody = "<env:Envelope xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\" xmlns:env=\"http://schemas.xmlsoap.org/soap/envelope/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\"><env:Body><Login xmlns=\"urn:vim25\"><_this type=\"SessionManager\">\(self.sessionManagerName.htmlEncode())</_this><userName>\(username.htmlEncode())</userName><password>\(password.htmlEncode())</password></Login></env:Body></env:Envelope>".dataUsingEncoding(NSUTF8StringEncoding)

        httpSession.dataTaskWithRequest(urlRequest) { (data, response, error) -> Void in
            let xml = try! NSXMLDocument(data: data!, options: 0)

            let sessionKeyNode = try! xml.nodesForXPath("//*[name()='key']")
            self.sessionKey = sessionKeyNode[0].stringValue!

            print("session key is \(self.sessionKey)")
            
            self.acquireTicket()
        }.resume()
    }
    
    func acquireTicket() {
        let urlRequest = NSMutableURLRequest(URL: serverURL)
        urlRequest.HTTPMethod = "POST"
        urlRequest.addValue("urn:vim25/5.5", forHTTPHeaderField: "SOAPAction")
        urlRequest.HTTPBody = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><soapenv:Envelope xmlns:soapenc=\"http://schemas.xmlsoap.org/soap/encoding/\" xmlns:soapenv=\"http://schemas.xmlsoap.org/soap/envelope/\" xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\"><soapenv:Body><AcquireTicket xmlns=\"urn:vim25\"><_this type=\"VirtualMachine\">\(self.vmId.htmlEncode())</_this><ticketType>mks</ticketType></AcquireTicket></soapenv:Body></soapenv:Envelope>".dataUsingEncoding(NSUTF8StringEncoding)
        
        httpSession.dataTaskWithRequest(urlRequest) { (data, response, error) -> Void in
            let xml = try! NSXMLDocument(data: data!, options: 0)
            
            let ticketNode = try! xml.nodesForXPath("//*[name()='ticket']")
            let cfgFileNode = try! xml.nodesForXPath("//*[name()='cfgFile']")
            let portNode = try! xml.nodesForXPath("//*[name()='port']")
            let sslThumbprintNode = try! xml.nodesForXPath("//*[name()='sslThumbprint']")
            
            let ticket = ticketNode[0].stringValue!
            let cfgFile = cfgFileNode[0].stringValue!
            let port = Int(portNode[0].stringValue!)!
            let sslThumbprint = sslThumbprintNode[0].stringValue!

            print("mks ticket is \(ticket)")
            self.connectConsole(ticket, cfgFile: cfgFile, port: port, sslThumbprint: sslThumbprint)
        }.resume()
    }
    
    func connectConsole(ticket: String, cfgFile: String, port: Int, sslThumbprint: String) {
        NSStream.getStreamsToHostWithName(server, port: port, inputStream: &self.vmwInputStream, outputStream: &self.vmwOutputStream)
        
        self.vmwInputStream?.open()
        self.vmwOutputStream?.open()
        self.sslSocketPair = (self.vmwInputStream, self.vmwOutputStream)
        
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
        SSLSetConnection(ctx!, &self.sslSocketPair)
        let r1 = SSLHandshake(ctx!)
        if r1 != -9841 { //errSSLServerAuthCompleted {
            fatalError("weird server error \(r1)")
        }
        let r2 = SSLHandshake(ctx!)

        /*
         > USER 52cf8c64-9343-7cb7-d151-1bfc481bb7d5
         */

        var written : Int = 0
        let loginMessage = "USER \(ticket)\r\n".dataUsingEncoding(NSUTF8StringEncoding)
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
        
        let passMessage = "PASS \(ticket)\r\n".dataUsingEncoding(NSUTF8StringEncoding)
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

        let connectMessage = "CONNECT \(cfgFile) mks\r\n".dataUsingEncoding(NSUTF8StringEncoding)
        let r9 = SSLWrite(ctx!, connectMessage!.bytes, connectMessage!.length, &written)
        
        /*
         < Connect /vmfs/volumes/56d5c29a-ac1ca31f-fd75-089e01d8b64c/scottjg-enterprise2-test/scottjg-enterprise2-test.vmx
         */
        
        let r10 = SSLRead(ctx!, &readBuffer, 8192, &written)
        let str4 = String(data: NSData(bytes: readBuffer, length: written), encoding: NSUTF8StringEncoding)!
        print(str4)

        self.sslCtx = SSLCreateContext(kCFAllocatorDefault, SSLProtocolSide.ClientSide, SSLConnectionType.StreamType)
        
        SSLSetSessionOption(self.sslCtx!, SSLSessionOption.BreakOnServerAuth, true)
        SSLSetIOFuncs(self.sslCtx!, sslReadCallback, sslWriteCallback)
        SSLSetConnection(self.sslCtx!, &self.sslSocketPair)
        let r11 = SSLHandshake(self.sslCtx!)
        if r11 != -9841 { //errSSLServerAuthCompleted {
            fatalError("weird server error \(r11)")
        }
        let r12 = SSLHandshake(self.sslCtx!)
        let randomMessage = "eJBwxqmgapMm7Nom".dataUsingEncoding(NSUTF8StringEncoding)

        
        self.vmwInputStream?.delegate = self
        self.vmwInputStream?.scheduleInRunLoop(.mainRunLoop(), forMode: NSDefaultRunLoopMode)

        let r13 = SSLWrite(self.sslCtx!, randomMessage!.bytes, randomMessage!.length, &written)

        startVncProxyServer()
    }
    
    func startVncProxyServer() {
        var socketContext = CFSocketContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        let socket = CFSocketCreate(kCFAllocatorDefault, PF_INET, SOCK_STREAM, IPPROTO_TCP, CFSocketCallBackType.AcceptCallBack.rawValue, acceptVncClientConnection, &socketContext)

        let fd = CFSocketGetNative(socket)
        var reuse = true
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(sizeof(Int32)))

        var addr = sockaddr_in(sin_len: 0, sin_family: 0, sin_port: 0, sin_addr: in_addr(s_addr: 0), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        addr.sin_len = UInt8(sizeofValue(addr))
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = UInt32(0x7F000001).bigEndian
        addr.sin_port = UInt16(12345).bigEndian
        
        let ptr = withUnsafeMutablePointer(&addr){UnsafeMutablePointer<UInt8>($0)}
        let data = CFDataCreate(nil, ptr, sizeof(sockaddr_in))
        let r = CFSocketSetAddress(socket, data)


        let eventSource = CFSocketCreateRunLoopSource(
            kCFAllocatorDefault,
            socket,
            0);
        
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            eventSource,
            kCFRunLoopDefaultMode);

        print("waiting for incoming connection...")
        NSWorkspace.sharedWorkspace().openURL(NSURL(string: "vnc://abc:123@localhost:12345")!)
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
        self.clientInputStream?.scheduleInRunLoop(.mainRunLoop(), forMode: NSDefaultRunLoopMode)
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
                if r == errSSLWouldBlock {
                    continue
                }
                assert(readSize > 0)
                let written = self.clientOutputStream?.write(buffer, maxLength: readSize)
                assert(written == readSize)
            }
        } else if aStream.isEqual(self.clientInputStream) {
            //print("clientinputstream event!")
            while self.clientInputStream!.hasBytesAvailable {
                var buffer = [UInt8](count: 8192, repeatedValue: 0)
                let readSize = self.clientInputStream?.read(&buffer, maxLength: buffer.count)
                assert(readSize > 0)
                var written : Int = 0
                SSLWrite(self.sslCtx!, buffer, readSize!, &written)
                assert(written == readSize!)
            }
        } else {
            print("unknown stream event!")
        }
    }
}

func acceptVncClientConnection(s: CFSocket!, callbackType: CFSocketCallBackType, address: CFData!, data: UnsafePointer<Void>, info: UnsafeMutablePointer<Void>) {
    let appDelegate = NSApplication.sharedApplication().delegate as! AppDelegate

    let sockAddr = UnsafePointer<sockaddr_in>(CFDataGetBytePtr(address))
    let ipAddress = inet_ntoa(sockAddr.memory.sin_addr)
    let addrData = NSData(bytes: ipAddress, length: Int(INET_ADDRSTRLEN))
    let ipAddressStr = NSString(data: addrData, encoding: NSUTF8StringEncoding)!
    print("Received a connection from \(ipAddressStr)")

    let clientSocketHandle = UnsafePointer<CFSocketNativeHandle>(data).memory
    
    var readStream : Unmanaged<CFReadStream>?
    var writeStream : Unmanaged<CFWriteStream>?
    CFStreamCreatePairWithSocket(kCFAllocatorDefault, clientSocketHandle, &readStream, &writeStream)
    
    let inputStream : NSInputStream = readStream!.takeRetainedValue()
    let outputStream : NSOutputStream = writeStream!.takeRetainedValue()
    
    inputStream.open()
    outputStream.open()
    
    appDelegate.handleVncProxyClient(inputStream, outputStream: outputStream)
}

func sslReadCallback(connection: SSLConnectionRef,
                     data: UnsafeMutablePointer<Void>,
                     dataLength: UnsafeMutablePointer<Int>) -> OSStatus {
    //let sockets = UnsafeMutablePointer<(NSInputStream?, NSOutputStream?)>(connection).memory
    //let inputStream = sockets.0!
    let appDelegate = NSApplication.sharedApplication().delegate as! AppDelegate
    let inputStream = appDelegate.vmwInputStream!
    let expectedReadSize = dataLength.memory
    let size = inputStream.read(UnsafeMutablePointer<UInt8>(data), maxLength: expectedReadSize)
    dataLength.memory = size
    if (size < expectedReadSize) {
        //print("would have blocked. read \(size) of \(expectedReadSize)")
        return Int32(errSSLWouldBlock)
    }

    return 0
}

func sslWriteCallback(connection: SSLConnectionRef,
                      data: UnsafePointer<Void>,
                      dataLength: UnsafeMutablePointer<Int>) -> OSStatus {
    //let sockets = UnsafeMutablePointer<(NSInputStream?, NSOutputStream?)>(connection).memory
    //let outputStream = sockets.1!
    let appDelegate = NSApplication.sharedApplication().delegate as! AppDelegate
    let outputStream = appDelegate.vmwOutputStream!

    outputStream.write(UnsafePointer<UInt8>(data), maxLength: dataLength.memory)
    return 0
}

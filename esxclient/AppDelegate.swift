//
//  AppDelegate.swift
//  esxclient
//
//  Created by Scott Goldman on 4/7/16.
//  Copyright © 2016 scottjg. All rights reserved.
//

import Cocoa

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {

    @IBOutlet weak var window: NSWindow!
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
        var inputStream: NSInputStream?
        var outputStream: NSOutputStream?

        NSStream.getStreamsToHostWithName(server, port: port, inputStream: &inputStream, outputStream: &outputStream)
        
        inputStream?.open()
        outputStream?.open()
        
        var readBuffer = [UInt8](count: 8192, repeatedValue: 0)
        let size = inputStream?.read(&readBuffer, maxLength: readBuffer.count)

        let str = String(data: NSData(bytes: readBuffer, length: size!), encoding: NSUTF8StringEncoding)!
        print(str)
/*
 < 220 VMware Authentication Daemon Version 1.10: SSL Required, ServerDaemonProtocol:SOAP, MKSDisplayProtocol:VNC , VMXARGS supported, NFCSSL supported
*/
        let ctx = SSLCreateContext(kCFAllocatorDefault, SSLProtocolSide.ClientSide, SSLConnectionType.StreamType)
        //XXX do ssl stuff`
        
        
/*
 > USER 52cf8c64-9343-7cb7-d151-1bfc481bb7d5
 < 331 Password required for 52cf8c64-9343-7cb7-d151-1bfc481bb7d5.
 < 230 User 52cf8c64-9343-7cb7-d151-1bfc481bb7d5 logged in.
 < 200 C5:50:62:9F:97:1D:AF:96:91:0B:2D:0E:2A:CA:2E:52:FB:60:87:73
 < 200 Connect /vmfs/volumes/56d5c29a-ac1ca31f-fd75-089e01d8b64c/scottjg-enterprise2-test/scottjg-enterprise2-test.vmx
 */

        
    }
}

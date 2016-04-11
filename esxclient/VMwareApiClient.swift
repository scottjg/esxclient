//
//  VMwareApiClient.swift
//  esxclient
//
//  Created by Scott Goldman on 4/9/16.
//  Copyright © 2016 scottjg. All rights reserved.
//

import Foundation

class VMwareApiClient {
    var username: String
    var password: String
    var host: String

    var httpSession: NSURLSession
    var serverURL : NSURL?

    enum ServerType { case Unknown, Host, Cluster }
    var serverType : ServerType = ServerType.Unknown
    var apiVersion : String = ""

    var sessionManagerName : String = ""
    var sessionKey : String = ""

    var vmId: String = "114"

    init(username: String, password: String, host: String) {
        self.username = username
        self.password = password
        self.host = host
        self.serverURL = NSURL(string: "https://\(self.host)/sdk")

        httpSession = NSURLSession(configuration: NSURLSession.sharedSession().configuration, delegate: NSURLSessionDelegator(), delegateQueue: NSURLSession.sharedSession().delegateQueue)
    }
    
    func login(callback: () -> Void) {
        if self.sessionManagerName == "" {
            self.getServiceContentMsg() {
                self.loginMsg() {
                    callback()
                }
            }
        } else {
            self.loginMsg() {
                callback()
            }
        }
    }

    func getServiceContentMsg(callback: () -> Void) {
        let urlRequest = NSMutableURLRequest(URL: self.serverURL!)
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
            callback()
        }.resume()
    }
    
    
    func loginMsg(callback: () -> Void) {
        let urlRequest = NSMutableURLRequest(URL: self.serverURL!)
        urlRequest.HTTPMethod = "POST"
        urlRequest.HTTPBody = "<env:Envelope xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\" xmlns:env=\"http://schemas.xmlsoap.org/soap/envelope/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\"><env:Body><Login xmlns=\"urn:vim25\"><_this type=\"SessionManager\">\(self.sessionManagerName.htmlEncode())</_this><userName>\(username.htmlEncode())</userName><password>\(password.htmlEncode())</password></Login></env:Body></env:Envelope>".dataUsingEncoding(NSUTF8StringEncoding)
        
        httpSession.dataTaskWithRequest(urlRequest) { (data, response, error) -> Void in
            let xml = try! NSXMLDocument(data: data!, options: 0)
            
            let sessionKeyNode = try! xml.nodesForXPath("//*[name()='key']")
            self.sessionKey = sessionKeyNode[0].stringValue!
            callback()
        }.resume()
    }
    
    func acquireMksTicket(vmId: String, callback: (ticket: String, cfgFile: String, port: UInt16, sslThumbprint: String) -> Void) {
        let urlRequest = NSMutableURLRequest(URL: self.serverURL!)
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
            let port = UInt16(portNode[0].stringValue!)!
            let sslThumbprint = sslThumbprintNode[0].stringValue!
            callback(ticket: ticket, cfgFile: cfgFile, port: port, sslThumbprint: sslThumbprint)
        }.resume()
    }
}
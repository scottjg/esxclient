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
    var rootFolderName : String = ""
    var propertyCollectorName : String = ""

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

            let rootFolderNode = try! xml.nodesForXPath("//*[name()='rootFolder']")
            self.rootFolderName = rootFolderNode[0].stringValue!

            let propertyCollectorNode = try! xml.nodesForXPath("//*[name()='propertyCollector']")
            self.propertyCollectorName = propertyCollectorNode[0].stringValue!

            callback()
        }.resume()
    }
    
    
    func loginMsg(callback: () -> Void) {
        let urlRequest = NSMutableURLRequest(URL: self.serverURL!)
        urlRequest.HTTPMethod = "POST"
        urlRequest.HTTPBody = "<env:Envelope xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\" xmlns:env=\"http://schemas.xmlsoap.org/soap/envelope/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\"><env:Body><Login xmlns=\"urn:vim25\"><_this type=\"SessionManager\">\(self.sessionManagerName.htmlEncode())</_this><userName>\(username.htmlEncode())</userName><password>\(password.htmlEncode())</password></Login></env:Body></env:Envelope>".dataUsingEncoding(NSUTF8StringEncoding)
        
        httpSession.dataTaskWithRequest(urlRequest) { (data, response, error) -> Void in
            let xml = try! NSXMLDocument(data: data!, options: 0)
            print (xml)
            let sessionKeyNode = try! xml.nodesForXPath("//*[name()='key']")
            self.sessionKey = sessionKeyNode[0].stringValue!
            callback()
        }.resume()
    }
    
    func acquireMksTicket(vmId: String, callback: (ticket: String, cfgFile: String, port: UInt16, sslThumbprint: String) -> Void) {
        let urlRequest = NSMutableURLRequest(URL: self.serverURL!)
        urlRequest.HTTPMethod = "POST"
        urlRequest.addValue("urn:vim25/\(self.apiVersion)", forHTTPHeaderField: "SOAPAction")
        urlRequest.HTTPBody = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><soapenv:Envelope xmlns:soapenc=\"http://schemas.xmlsoap.org/soap/encoding/\" xmlns:soapenv=\"http://schemas.xmlsoap.org/soap/envelope/\" xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\"><soapenv:Body><AcquireTicket xmlns=\"urn:vim25\"><_this type=\"VirtualMachine\">\(vmId.htmlEncode())</_this><ticketType>mks</ticketType></AcquireTicket></soapenv:Body></soapenv:Envelope>".dataUsingEncoding(NSUTF8StringEncoding)
        
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

    func powerOnVM(vmId: String, callback: (status: String) -> Void) {
        let urlRequest = NSMutableURLRequest(URL: self.serverURL!)
        urlRequest.HTTPMethod = "POST"
        urlRequest.addValue("urn:vim25/\(self.apiVersion)", forHTTPHeaderField: "SOAPAction")
        urlRequest.HTTPBody = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><env:Envelope xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\" xmlns:env=\"http://schemas.xmlsoap.org/soap/envelope/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\"><env:Body><PowerOnVM_Task xmlns=\"urn:vim25\"><_this type=\"VirtualMachine\">\(vmId.htmlEncode())</_this></PowerOnVM_Task></env:Body></env:Envelope>".dataUsingEncoding(NSUTF8StringEncoding)
        
        httpSession.dataTaskWithRequest(urlRequest) { (data, response, error) -> Void in
            let xml = try! NSXMLDocument(data: data!, options: 0)
            let returnValNode = try! xml.nodesForXPath("//*[name()='returnval']")
            let task = returnValNode[0].stringValue!
            self.waitForTask(task) { (status) -> Void in
                callback(status: status)
            }
        }.resume()
    }
    
    func waitForTask(taskId: String, callback: (status: String) -> Void) {
        let urlRequest = NSMutableURLRequest(URL: self.serverURL!)
        urlRequest.HTTPMethod = "POST"
        urlRequest.addValue("urn:vim25/\(self.apiVersion)", forHTTPHeaderField: "SOAPAction")
        urlRequest.HTTPBody = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><env:Envelope xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\" xmlns:env=\"http://schemas.xmlsoap.org/soap/envelope/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\"><env:Body><CreateFilter xmlns=\"urn:vim25\"><_this type=\"PropertyCollector\">\(self.propertyCollectorName)</_this><spec xsi:type=\"PropertyFilterSpec\"><propSet xsi:type=\"PropertySpec\"><type>Task</type><all>0</all><pathSet>info.progress</pathSet><pathSet>info.state</pathSet><pathSet>info.entityName</pathSet><pathSet>info.error</pathSet><pathSet>info.name</pathSet></propSet><objectSet xsi:type=\"ObjectSpec\"><obj type=\"Task\">\(taskId.htmlEncode())</obj></objectSet></spec><partialUpdates>0</partialUpdates></CreateFilter></env:Body></env:Envelope>".dataUsingEncoding(NSUTF8StringEncoding)
        httpSession.dataTaskWithRequest(urlRequest) { (data, response, error) -> Void in
            //let xml = try! NSXMLDocument(data: data!, options: 0)
            self.pollTask() { (status) -> Void in
                callback(status: status)
            }
        }.resume()
        
    }
    
    func pollTask(callback: (status: String) -> Void) {
        let urlRequest = NSMutableURLRequest(URL: self.serverURL!)
        urlRequest.HTTPMethod = "POST"
        urlRequest.addValue("urn:vim25/\(self.apiVersion)", forHTTPHeaderField: "SOAPAction")
        urlRequest.HTTPBody = "<env:Envelope xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\" xmlns:env=\"http://schemas.xmlsoap.org/soap/envelope/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\"><env:Body><WaitForUpdates xmlns=\"urn:vim25\"><_this type=\"PropertyCollector\">\(self.propertyCollectorName)</_this><version></version></WaitForUpdates></env:Body></env:Envelope>".dataUsingEncoding(NSUTF8StringEncoding)
        self.httpSession.dataTaskWithRequest(urlRequest) { (data, response, error) -> Void in
            let xml = try! NSXMLDocument(data: data!, options: 0)
            let changesetNodes = try! xml.nodesForXPath("//*[name()='changeSet']")
            for changesetNode in changesetNodes {
                let name = try! changesetNode.nodesForXPath("*[name()='name']")
                if (name[0].stringValue! == "info.state") {
                    let valNode = try! changesetNode.nodesForXPath("*[name()='val']")
                    let val = valNode[0].stringValue!
                    if (val != "running") {
                        callback(status: val)
                    } else {
                        self.pollTask() { (status) -> Void in
                            callback(status: status)
                        }
                    }
                    break
                }
            }
            
        }.resume()
    }

    func powerOffVM(vmId: String, callback: (status: String) -> Void) {
        let urlRequest = NSMutableURLRequest(URL: self.serverURL!)
        urlRequest.HTTPMethod = "POST"
        urlRequest.addValue("urn:vim25/\(self.apiVersion)", forHTTPHeaderField: "SOAPAction")
        urlRequest.HTTPBody = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><env:Envelope xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\" xmlns:env=\"http://schemas.xmlsoap.org/soap/envelope/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\"><env:Body><PowerOffVM_Task xmlns=\"urn:vim25\"><_this type=\"VirtualMachine\">\(vmId.htmlEncode())</_this></PowerOffVM_Task></env:Body></env:Envelope>".dataUsingEncoding(NSUTF8StringEncoding)
        
        httpSession.dataTaskWithRequest(urlRequest) { (data, response, error) -> Void in
            let xml = try! NSXMLDocument(data: data!, options: 0)
            let returnValNode = try! xml.nodesForXPath("//*[name()='returnval']")
            let task = returnValNode[0].stringValue!
            self.waitForTask(task) { (status) -> Void in
                callback(status: status)
            }
        }.resume()
    }

    func getVMScreenshot(vmId: String, callback: (imageData: NSData) -> Void) {
        //XXX need urlencode
        let urlRequest = NSMutableURLRequest(URL: NSURL(string: "https://\(self.host)/screen?id=\(vmId)")!)
        urlRequest.HTTPMethod = "GET"
        
        let base64creds = "\(self.username):\(self.password)".dataUsingEncoding(NSUTF8StringEncoding)?.base64EncodedDataWithOptions(NSDataBase64EncodingOptions(rawValue: 0))
        urlRequest.addValue("Basic \(base64creds)", forHTTPHeaderField: "Authorization")
        
        
        httpSession.dataTaskWithRequest(urlRequest) { (data, response, error) -> Void in
            print(response)
            callback(imageData: data!)
        }.resume()
    }


    func getVMs(callback: (virtualMachines: [[String: String]]) -> Void) {
        let urlRequest = NSMutableURLRequest(URL: self.serverURL!)
        urlRequest.HTTPMethod = "POST"
        urlRequest.addValue("urn:vim25/\(self.apiVersion)", forHTTPHeaderField: "SOAPAction")
        urlRequest.HTTPBody = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><soapenv:Envelope xmlns:soapenc=\"http://schemas.xmlsoap.org/soap/encoding/\" xmlns:soapenv=\"http://schemas.xmlsoap.org/soap/envelope/\" xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\"><soapenv:Body><CreateContainerView xmlns=\"urn:vim25\"><_this type=\"ViewManager\">ViewManager</_this><container type=\"Folder\">\(self.rootFolderName.htmlEncode())</container><type>VirtualMachine</type><recursive>true</recursive></CreateContainerView></soapenv:Body></soapenv:Envelope>".dataUsingEncoding(NSUTF8StringEncoding)
        
        httpSession.dataTaskWithRequest(urlRequest) { (data, response, error) -> Void in
            let xml = try! NSXMLDocument(data: data!, options: 0)
            
            let returnValNode = try! xml.nodesForXPath("//*[name()='returnval']")
            let containerView = returnValNode[0].stringValue!

            let urlRequest = NSMutableURLRequest(URL: self.serverURL!)
            urlRequest.HTTPMethod = "POST"
            urlRequest.addValue("urn:vim25/\(self.apiVersion)", forHTTPHeaderField: "SOAPAction")
            urlRequest.HTTPBody = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><soapenv:Envelope xmlns:soapenc=\"http://schemas.xmlsoap.org/soap/encoding/\" xmlns:soapenv=\"http://schemas.xmlsoap.org/soap/envelope/\" xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\"><soapenv:Body><RetrievePropertiesEx xmlns=\"urn:vim25\"><_this type=\"PropertyCollector\">\(self.propertyCollectorName)</_this><specSet><propSet><type>ContainerView</type><all>false</all><pathSet>view</pathSet></propSet><objectSet><obj type=\"ContainerView\">\(containerView.htmlEncode())</obj><skip>false</skip></objectSet></specSet><options></options></RetrievePropertiesEx></soapenv:Body></soapenv:Envelope>".dataUsingEncoding(NSUTF8StringEncoding)
            
            self.httpSession.dataTaskWithRequest(urlRequest) { (data, response, error) -> Void in
                let xml = try! NSXMLDocument(data: data!, options: 0)
                
                var xmlResponse = "<env:Envelope xmlns:env=\"http://schemas.xmlsoap.org/soap/envelope/\" xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">" +
                        "<env:Body>" +
                            "<RetrieveProperties xmlns=\"urn:vim25\">" +
                                "<_this type=\"PropertyCollector\">\(self.propertyCollectorName)</_this>" +
                                "<specSet xsi:type=\"PropertyFilterSpec\">" +
                                    "<propSet xsi:type=\"PropertySpec\">" +
                                        "<type>VirtualMachine</type>" +
                                        "<pathSet>name</pathSet>" +
                                        "<pathSet>runtime.powerState</pathSet>" +
                                        "<pathSet>runtime.connectionState</pathSet>" +
                                        "<pathSet>name</pathSet>" +
                                        "<pathSet>overallStatus</pathSet>" +
                                    "</propSet>"

                let vmNodes = try! xml.nodesForXPath("//*[name()='val']/*[name()='ManagedObjectReference']")
                for vmNode in vmNodes {
                    let vmId = vmNode.stringValue!
                    xmlResponse = xmlResponse + "<objectSet xsi:type=\"ObjectSpec\">" +
                                                    "<obj type=\"VirtualMachine\">\(vmId.htmlEncode())</obj>" +
                                                "</objectSet>"
                }

                xmlResponse = xmlResponse +
                                "</specSet>" +
                            "</RetrieveProperties>" +
                        "</env:Body>" +
                    "</env:Envelope>"
                
                let urlRequest = NSMutableURLRequest(URL: self.serverURL!)
                urlRequest.HTTPMethod = "POST"
                urlRequest.addValue("urn:vim25/\(self.apiVersion)", forHTTPHeaderField: "SOAPAction")
                urlRequest.HTTPBody = xmlResponse.dataUsingEncoding(NSUTF8StringEncoding)
                self.httpSession.dataTaskWithRequest(urlRequest) { (data, response, error) -> Void in
                    var virtualMachines = [[String: String]]()
                    let xml = try! NSXMLDocument(data: data!, options: 0)
                    let returnValNodes = try! xml.nodesForXPath("//*[name()='returnval']")
                    for returnValNode in returnValNodes {
                        var virtualMachine = [String: String]()
                        
                        let vmIdNode = try! returnValNode.nodesForXPath("*[name()='obj']")
                        let vmId = vmIdNode[0].stringValue!
                        virtualMachine["id"] = vmId
                        
                        let props = try! returnValNode.nodesForXPath("*[name()='propSet']")
                        for prop in props {
                            let nameNode = try! prop.nodesForXPath("*[name()='name']")
                            let name = nameNode[0].stringValue!

                            let valNode = try! prop.nodesForXPath("*[name()='val']")
                            let val = valNode[0].stringValue!

                            virtualMachine[name] = val
                        }
                        virtualMachines.append(virtualMachine)
                    }
                    callback(virtualMachines: virtualMachines)
                }.resume()
            }.resume()
        }.resume()
    }
}
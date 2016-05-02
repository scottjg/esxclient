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
    var lastUpdateVersion = ""

    var vmList = [String: [String: String]]()
    var vmUpdateCallback : ((virtualMachines: [String: [String: String]]) -> Void)? = nil

    enum VMError : Int {
        case InvalidLoginFault = -1
        case ResponseParseError = -2
        case UnknownError = -3
    }
    
    init(username: String, password: String, host: String) {
        self.username = username
        self.password = password
        self.host = host
        self.serverURL = NSURL(string: "https://\(self.host)/sdk")

        httpSession = NSURLSession(configuration: NSURLSession.sharedSession().configuration, delegate: NSURLSessionDelegator(), delegateQueue: NSURLSession.sharedSession().delegateQueue)
    }
    
    func login(callback: (error: NSError?) -> Void) {
        if self.sessionManagerName == "" {
            self.getServiceContentMsg() { (error: NSError?) -> Void in
                if error != nil {
                    callback(error: error)
                    return
                }

                self.loginMsg() { (error: NSError?) -> Void in
                    callback(error: error)
                }
            }
        } else {
            self.loginMsg() { (error: NSError?) -> Void in
                callback(error: error)
            }
        }
    }

    func getServiceContentMsg(callback: (error: NSError?) -> Void) {
        self.doRequest("<RetrieveServiceContent xmlns=\"urn:internalvim25\"><_this type=\"ServiceInstance\">ServiceInstance</_this></RetrieveServiceContent>") { (data, response, error) -> Void in
            if error != nil {
                callback(error: error)
                return
            }

            let results : [String]
            do {
                results = try self.processXML(data, getFields: [
                    "vim:RetrieveServiceContentResponse/vim:returnval/vim:about/vim:apiVersion",
                    "vim:RetrieveServiceContentResponse/vim:returnval/vim:about/vim:apiType",
                    "vim:RetrieveServiceContentResponse/vim:returnval/vim:rootFolder",
                    "vim:RetrieveServiceContentResponse/vim:returnval/vim:propertyCollector",
                    "vim:RetrieveServiceContentResponse/vim:returnval/vim:sessionManager"
                    ])
            } catch let err as NSError {
                callback(error: err)
                return
            }

            self.apiVersion = results[0]
            let apiType = results[1]
            
            print("api version is \(self.apiVersion) / \(apiType)")
            if apiType == "HostAgent" {
                self.serverType = ServerType.Host
            }
            
            self.rootFolderName = results[2]
            self.propertyCollectorName = results[3]
            self.sessionManagerName = results[4]

            callback(error: error)
        }
    }
    
    
    func loginMsg(callback: (error: NSError?) -> Void) {
        self.doRequest("<Login xmlns=\"urn:internalvim25\"><_this type=\"SessionManager\">\(self.sessionManagerName.htmlEncode())</_this><userName>\(username.htmlEncode())</userName><password>\(password.htmlEncode())</password></Login>") { (data, response, error) -> Void in

            if error != nil {
                callback(error: error)
            }
            
            let results : [String]
            do {
                results = try self.processXML(data, getFields: [
                    "vim:LoginResponse/vim:returnval/vim:key"
                    ])
            } catch let err as NSError {
                callback(error: err)
                return
            }

            
            self.sessionKey = results[0]
            callback(error: nil)
        }
    }
    
    func acquireMksTicket(vmId: String, callback: (ticket: String, cfgFile: String, port: UInt16, sslThumbprint: String) -> Void) {
        self.doRequest("<AcquireTicket xmlns=\"urn:internalvim25\"><_this type=\"VirtualMachine\">\(vmId.htmlEncode())</_this><ticketType>mks</ticketType></AcquireTicket>") { (data, response, error) -> Void in

            let results : [String]
            do {
                results = try self.processXML(data, getFields: [
                    "vim:AcquireTicketResponse/vim:returnval/vim:ticket",
                    "vim:AcquireTicketResponse/vim:returnval/vim:cfgFile",
                    "vim:AcquireTicketResponse/vim:returnval/vim:port",
                    "vim:AcquireTicketResponse/vim:returnval/vim:sslThumbprint",
                    ])
            } catch let err as NSError {
                //callback(error: err)
                return
            }
            
            if let port = UInt16(results[2]) {
                callback(
                    ticket: results[0],
                    cfgFile: results[1],
                    port: port,
                    sslThumbprint: results[3]
                )
            } else {
                //callback(err: NSError(domain: "myapp", code: VMError.ResponseParseError.rawValue, userInfo: nil))
            }
        }
    }

    func powerOnVM(vmId: String, callback: (progress: Int, status: String) -> Void) {
        self.doRequest("<PowerOnVM_Task xmlns=\"urn:internalvim25\"><_this type=\"VirtualMachine\">\(vmId.htmlEncode())</_this></PowerOnVM_Task>") { (data, response, error) -> Void in
            
            let results : [String]
            do {
                results = try self.processXML(data, getFields: [
                    "vim:PowerOnVM_TaskResponse/vim:returnval"
                    ])
            } catch let err as NSError {
                //callback(error: err)
                return
            }

            let task = results[0]
            self.waitForTask(task) { (progress, status) -> Void in
                callback(progress: progress, status: status)
            }
        }
    }
    
    func waitForTask(taskId: String, callback: (progress: Int, status: String) -> Void) {
        self.doRequest(
            "<CreateFilter xmlns=\"urn:internalvim25\">" +
                "<_this type=\"PropertyCollector\">\(self.propertyCollectorName)</_this>" +
                "<spec xsi:type=\"PropertyFilterSpec\">" +
                    "<propSet xsi:type=\"PropertySpec\">" +
                        "<type>Task</type>" +
                        "<all>0</all>" +
                        "<pathSet>info.progress</pathSet>" +
                        "<pathSet>info.state</pathSet>" +
                        "<pathSet>info.entityName</pathSet>" +
                        "<pathSet>info.error</pathSet>" +
                        "<pathSet>info.name</pathSet>" +
                    "</propSet>" +
                    "<objectSet xsi:type=\"ObjectSpec\">" +
                        "<obj type=\"Task\">\(taskId.htmlEncode())</obj>" +
                    "</objectSet>" +
                "</spec>" +
                "<partialUpdates>0</partialUpdates>" +
            "</CreateFilter>"
        ) { (data, response, error) -> Void in

            //let xml = try! NSXMLDocument(data: data!, options: 0)
            //self.pollTask() { (progress, status) -> Void in
            //    callback(progress: progress, status: status)
            //}
        }
    }
    
    func pollForUpdates(callback: (progress: Int, status: String) -> Void) {
        self.doRequest("<WaitForUpdates xmlns=\"urn:internalvim25\"><_this type=\"PropertyCollector\">\(self.propertyCollectorName)</_this><version>\(self.lastUpdateVersion.htmlEncode())</version></WaitForUpdates>") { (data, response, error) -> Void in

            if error != nil && error!.code == -1001 { //time out
                self.pollForUpdates(callback)
                return
            }
/*
            let results : [String]
            do {
                results = try self.processXML(data, getFields: [
                    "vim:WaitForUpdatesResponse/vim:returnval/vim:version",
                    "vim:WaitForUpdatesResponse/vim:returnval/vim:filterSet",
                    ])
            } catch let err as NSError {
                //callback(error: err)
                return
            }
*/
            let xml = try! NSXMLDocument(data: data!, options: 0)
            let ns = NSXMLElement.namespaceWithName("vim", stringValue: "urn:internalvim25")
            xml.rootElement()!.addNamespace(ns as! NSXMLNode)
            print(xml)

            let versionNode = try! xml.nodesForXPath("/soapenv:Envelope/soapenv:Body/vim:WaitForUpdatesResponse/vim:returnval/vim:version")
            self.lastUpdateVersion = versionNode[0].stringValue!

            let filterSets = try! xml.nodesForXPath("/soapenv:Envelope/soapenv:Body/vim:WaitForUpdatesResponse/vim:returnval/vim:filterSet")
            for filterSet in filterSets {
                let filterNode = try! filterSet.nodesForXPath("vim:filter")
                let propertyFilterId = filterNode[0].stringValue!

                let vmSet = try! filterSet.nodesForXPath("vim:objectSet[vim:obj/@type = \"VirtualMachine\"]")
                if vmSet.count > 0 {
                    self.updateVirtualMachines(vmSet)
                }
            }
/*
            
            let changesetNodes = try! xml.nodesForXPath("//*[name()='changeSet']")
            var progress = 0
            var state = ""
            for changesetNode in changesetNodes {
                let name = try! changesetNode.nodesForXPath("*[name()='name']")
                if (name[0].stringValue! == "info.state") {
                    let valNode = try! changesetNode.nodesForXPath("*[name()='val']")
                    state = valNode[0].stringValue!
                } else if (name[0].stringValue! == "info.progress") {
                    let valNode = try! changesetNode.nodesForXPath("*[name()='val']")
                    if valNode.count > 0 {
                        let val = valNode[0].stringValue!
                        progress = Int(val)!
                    }
                }
            }

            callback(progress: progress, status: state)
*/*/
            self.pollForUpdates(callback)
        }
    }

    func powerOffVM(vmId: String, callback: (progress: Int, status: String) -> Void) {
        self.doRequest("<PowerOffVM_Task xmlns=\"urn:internalvim25\"><_this type=\"VirtualMachine\">\(vmId.htmlEncode())</_this></PowerOffVM_Task>") { (data, response, error) -> Void in

            let results : [String]
            do {
                results = try self.processXML(data, getFields: [
                    "vim:PowerOffVM_TaskResponse/vim:returnval"
                    ])
            } catch let err as NSError {
                //callback(error: err)
                return
            }

            let task = results[0]
            self.waitForTask(task) { (progress, status) -> Void in
                callback(progress: progress, status: status)
            }
        }
    }

    func getVMScreenshot(vmId: String, callback: (imageData: NSData) -> Void) {
        let urlRequest = NSMutableURLRequest(URL: NSURL(string: "https://\(self.host)/screen?id=\(vmId.urlEncode())")!)
        urlRequest.HTTPMethod = "GET"
        
        let base64creds = "\(self.username):\(self.password)".dataUsingEncoding(NSUTF8StringEncoding)?.base64EncodedDataWithOptions(NSDataBase64EncodingOptions(rawValue: 0))
        urlRequest.addValue("Basic \(base64creds)", forHTTPHeaderField: "Authorization")
        
        
        httpSession.dataTaskWithRequest(urlRequest) { (data, response, error) -> Void in
            //print(response)
            if let imageData = data {
                callback(imageData: imageData)
            }
        }.resume()
    }


    func updateVirtualMachines(objSets: [NSXMLNode]) -> Void {
        var dirty = false
        for objSet in objSets {
            let objNode = try! objSet.nodesForXPath("vim:obj")
            let vmId = objNode[0].stringValue!
            
            let changeSets = try! objSet.nodesForXPath("vim:changeSet")
            for changeSet in changeSets {
                let nameNode = try! changeSet.nodesForXPath("vim:name")
                let name = nameNode[0].stringValue!

                let valNode = try! changeSet.nodesForXPath("vim:val")
                let val = valNode.count == 0 ? "" : valNode[0].stringValue!
                
                if self.vmList[vmId] == nil {
                    self.vmList[vmId] = [String: String]()
                    self.vmList[vmId]!["id"] = vmId
                    dirty = true
                }
                
                if (self.vmList[vmId]![name] != val) {
                    self.vmList[vmId]![name] = val
                    dirty = true
                }
            }

        }
        print(self.vmList)
        if (dirty) {
            self.vmUpdateCallback!(virtualMachines: self.vmList)
        }
    }
    
    func getVMs(vmUpdateCallback: (virtualMachines: [String: [String: String]]) -> Void) {
        self.vmUpdateCallback = vmUpdateCallback

        self.doRequest("<CreateContainerView xmlns=\"urn:internalvim25\"><_this type=\"ViewManager\">ViewManager</_this><container type=\"Folder\">\(self.rootFolderName.htmlEncode())</container><type>VirtualMachine</type><recursive>true</recursive></CreateContainerView>") { (data, response, error) -> Void in

            let results : [String]
            do {
                results = try self.processXML(data, getFields: [
                    "vim:CreateContainerViewResponse/vim:returnval"
                    ])
            } catch let err as NSError {
                //callback(error: err)
                return
            }

            let containerView = results[0]
            
            self.doRequest("<RetrievePropertiesEx xmlns=\"urn:internalvim25\"><_this type=\"PropertyCollector\">\(self.propertyCollectorName)</_this><specSet><propSet><type>ContainerView</type><all>false</all><pathSet>view</pathSet></propSet><objectSet><obj type=\"ContainerView\">\(containerView.htmlEncode())</obj><skip>false</skip></objectSet></specSet><options></options></RetrievePropertiesEx>") { (data, response, error) -> Void in

                let xml = try! NSXMLDocument(data: data!, options: 0)
                
                var xmlResponse =
                    "<CreateFilter xmlns=\"urn:internalvim25\">" +
                                "<_this type=\"PropertyCollector\">\(self.propertyCollectorName)</_this>" +
                                "<spec xsi:type=\"PropertyFilterSpec\">" +
                                    "<propSet xsi:type=\"PropertySpec\">" +
                                        "<type>VirtualMachine</type>" +
                                        "<pathSet>name</pathSet>" +
                                        "<pathSet>runtime.powerState</pathSet>" +
                                        "<pathSet>guest.ipAddress</pathSet>" +
                                    "</propSet>"

                let vmNodes = try! xml.nodesForXPath("//*[name()='val']/*[name()='ManagedObjectReference']")
                for vmNode in vmNodes {
                    let vmId = vmNode.stringValue!
                    xmlResponse = xmlResponse + "<objectSet xsi:type=\"ObjectSpec\">" +
                                                    "<obj type=\"VirtualMachine\">\(vmId.htmlEncode())</obj>" +
                                                "</objectSet>"
                }

                xmlResponse = xmlResponse +
                                "</spec>" +
                                "<partialUpdates>0</partialUpdates>" +
                            "</CreateFilter>"
                //print(xmlResponse)
                self.doRequest(xmlResponse) { (data, response, error) -> Void in
                    /*
                    var virtualMachines = [[String: String]]()
                    let xml = try! NSXMLDocument(data: data!, options: 0)
                    print(xml)
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
                    callback(virtualMachines: virtualMachines) */ */
                }
            }
        }
    }
    
    func doRequest(request: String, callback: (data: NSData?, response: NSURLResponse?, error: NSError?) -> Void) {
        
        let urlRequest = NSMutableURLRequest(URL: self.serverURL!)
        urlRequest.HTTPMethod = "POST"
        urlRequest.addValue("VMware VI Client/4.0.0", forHTTPHeaderField: "User-Agent")
        urlRequest.addValue("urn:internalvim25/\(self.apiVersion)", forHTTPHeaderField: "SOAPAction")
        urlRequest.HTTPBody = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><env:Envelope xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\" xmlns:env=\"http://schemas.xmlsoap.org/soap/envelope/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\"><env:Body>\(request)</env:Body></env:Envelope>".dataUsingEncoding(NSUTF8StringEncoding)
        
        httpSession.dataTaskWithRequest(urlRequest) { (data, response, error) -> Void in
            callback(data: data, response: response, error: error)
        }.resume()
    }
    
    func processXML(data: NSData?, getFields: [String]) throws -> [String] {
        let xml = try NSXMLDocument(data: data!, options: 0)
        let ns = NSXMLElement.namespaceWithName("vim", stringValue: "urn:internalvim25")
        xml.rootElement()!.addNamespace(ns as! NSXMLNode)

        
        let soapBody = try xml.nodesForXPath("/soapenv:Envelope/soapenv:Body")
        guard soapBody.count > 0 else {
            throw NSError(domain: "myapp", code: VMError.ResponseParseError.rawValue, userInfo: nil)
        }

        let fault = try soapBody[0].nodesForXPath("soapenv:Fault")
        guard fault.count == 0 else {
            let detailNode = try fault[0].nodesForXPath("detail")
            if detailNode.count > 0 && detailNode[0].children != nil && detailNode[0].children!.count > 0 {
                if let name = detailNode[0].children![0].name {
                    if name == "InvalidLoginFault" {
                        throw NSError(domain: "myapp", code: VMError.InvalidLoginFault.rawValue, userInfo: nil)
                    }
                }
            }
        
            let faultcodeNode = try fault[0].nodesForXPath("faultcode")
            let faultstringNode = try fault[0].nodesForXPath("faultstring")
        
            var dict = [NSObject: AnyObject]()
            if faultcodeNode.count > 0 {
                dict["faultcode"] = faultcodeNode[0].stringValue
            }
            if faultstringNode.count > 0 {
                dict["faultstring"] = faultstringNode[0].stringValue
            }
            if detailNode.count > 0 {
                dict["detailXML"] = detailNode[0].XMLString
            }
            throw NSError(domain: "myapp", code: VMError.UnknownError.rawValue, userInfo: dict)
        }
        
        var result = [String]()
        for xpath in getFields {
            let nodes = try soapBody[0].nodesForXPath(xpath)
            guard nodes.count > 0 && nodes[0].stringValue != nil else {
                throw NSError(domain: "myapp", code: VMError.ResponseParseError.rawValue, userInfo: nil)
            }
            result.append(nodes[0].stringValue!)
        }
        
        return result
    }
}
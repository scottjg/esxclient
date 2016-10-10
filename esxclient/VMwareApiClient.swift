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

    var httpSession: URLSession
    var serverURL : URL?

    enum ServerType { case unknown, host, cluster }
    var serverType : ServerType = ServerType.unknown
    var apiVersion : String = ""
    var fullName : String = ""

    var sessionManagerName : String = ""
    var sessionKey : String = ""
    var rootFolderName : String = ""
    var propertyCollectorName : String = ""
    var lastUpdateVersion = ""
    
    var errorHandler: (_ error: NSError) -> Void
    var updateHandler: (_ virtualMachines: [String: [String: String]]) -> Void
    var updateProgress: (_ progressPercent: Int, _ status: String) -> Void

    var vmList = [String: [String: String]]()
    var vmUpdateCallback : ((_ virtualMachines: [String: [String: String]]) -> Void)? = nil
    
    var cancelled = false

    enum VMError : Int {
        case invalidLoginFault = -1
        case responseParseError = -2
        case unknownError = -3
    }
    
    init(username: String, password: String, host: String,
         errorHandler: @escaping (_ error: NSError) -> Void,
         updateHandler: @escaping (_ virtualMachines: [String: [String: String]]) -> Void,
         updateProgress: @escaping (_ progressPercent: Int, _ status: String) -> Void
         ) {
        self.username = username
        self.password = password
        self.host = host
        self.serverURL = URL(string: "https://\(self.host)/sdk")

        httpSession = URLSession(configuration: URLSession.shared.configuration, delegate: NSURLSessionDelegator(), delegateQueue: URLSession.shared.delegateQueue)
        
        self.errorHandler = errorHandler
        self.updateHandler = updateHandler
        self.updateProgress = updateProgress
    }
    
    func startPollingForUpdates() {
        login() { () -> Void in
            self.pollForUpdates() { (progress, status) -> Void in
                self.updateProgress(progress, status)
            }
            self.getVMs() { (virtualMachines: [String: [String: String]]) -> Void in
                self.updateHandler(virtualMachines)
            }
        }
    }

    
    func login(_ callback: @escaping () -> Void) {
        if self.sessionManagerName == "" {
            self.getServiceContentMsg() { () -> Void in
                self.loginMsg() { () -> Void in
                    callback()
                }
            }
        } else {
            self.loginMsg() { () -> Void in
                callback()
            }
        }
    }

    func title() -> String {
        return "\(self.host) (\(self.fullName))"
    }
    
    func getServiceContentMsg(_ callback: @escaping () -> Void) {
        self.doRequest("<RetrieveServiceContent xmlns=\"urn:internalvim25\"><_this type=\"ServiceInstance\">ServiceInstance</_this></RetrieveServiceContent>") { (data, response, error) -> Void in
            if let err = error {
                self.errorHandler(err)
                return
            }

            let results : [String]
            do {
                results = try self.getXMLFields(data!, getFields: [
                    "vim:RetrieveServiceContentResponse/vim:returnval/vim:about/vim:apiVersion",
                    "vim:RetrieveServiceContentResponse/vim:returnval/vim:about/vim:apiType",
                    "vim:RetrieveServiceContentResponse/vim:returnval/vim:about/vim:fullName",
                    "vim:RetrieveServiceContentResponse/vim:returnval/vim:rootFolder",
                    "vim:RetrieveServiceContentResponse/vim:returnval/vim:propertyCollector",
                    "vim:RetrieveServiceContentResponse/vim:returnval/vim:sessionManager"
                    ])
            } catch let err as NSError {
                self.errorHandler(err)
                return
            }

            self.apiVersion = results[0]
            let apiType = results[1]
            
            print("api version is \(self.apiVersion) / \(apiType)")
            if apiType == "HostAgent" {
                self.serverType = ServerType.host
            }
            
            self.fullName = results[2]
            self.rootFolderName = results[3]
            self.propertyCollectorName = results[4]
            self.sessionManagerName = results[5]

            callback()
        }
    }
    
    
    func loginMsg(_ callback: @escaping () -> Void) {
        self.doRequest(
            "<Login xmlns=\"urn:internalvim25\">" +
                "<_this type=\"SessionManager\">\(self.sessionManagerName.htmlEncode())</_this>" +
                "<userName>\(username.htmlEncode())</userName>" +
                "<password>\(password.htmlEncode())</password>" +
            "</Login>"
        ) { (data, response, error) -> Void in

            if let err = error {
                self.errorHandler(err)
                return
            }
            
            let results : [String]
            do {
                results = try self.getXMLFields(data!, getFields: [
                    "vim:LoginResponse/vim:returnval/vim:key"
                    ])
            } catch let err as NSError {
                self.errorHandler(err)
                return
            }

            
            self.sessionKey = results[0]
            callback()
        }
    }
    
    func acquireMksTicket(_ vmId: String, callback: @escaping (_ ticket: String, _ cfgFile: String, _ port: UInt16, _ sslThumbprint: String) -> Void) {
        self.doRequest(
            "<AcquireTicket xmlns=\"urn:internalvim25\">" +
                "<_this type=\"VirtualMachine\">\(vmId.htmlEncode())</_this>" +
                "<ticketType>mks</ticketType>" +
            "</AcquireTicket>"
        ) { (data, response, error) -> Void in
            if let err = error {
                self.errorHandler(err)
                return
            }

            let results : [String]
            do {
                results = try self.getXMLFields(data!, getFields: [
                    "vim:AcquireTicketResponse/vim:returnval/vim:ticket",
                    "vim:AcquireTicketResponse/vim:returnval/vim:cfgFile",
                    "vim:AcquireTicketResponse/vim:returnval/vim:port",
                    "vim:AcquireTicketResponse/vim:returnval/vim:sslThumbprint",
                    ])
            } catch let err as NSError {
                self.errorHandler(err)
                return
            }
            
            if let port = UInt16(results[2]) {
                callback(
                    results[0],
                    results[1],
                    port,
                    results[3]
                )
            } else {
                self.errorHandler(NSError(domain: "myapp", code: VMError.responseParseError.rawValue, userInfo: nil))
            }
        }
    }

    func powerOnVM(_ vmId: String) {
        self.doRequest(
            "<PowerOnVM_Task xmlns=\"urn:internalvim25\">" +
                "<_this type=\"VirtualMachine\">\(vmId.htmlEncode())</_this>" +
            "</PowerOnVM_Task>"
        ) { (data, response, error) -> Void in
            if let err = error {
                self.errorHandler(err)
                return
            }
            
            let results : [String]
            do {
                results = try self.getXMLFields(data!, getFields: [
                    "vim:PowerOnVM_TaskResponse/vim:returnval"
                    ])
            } catch let err as NSError {
                self.errorHandler(err)
                return
            }

            let task = results[0]
            self.waitForTask(task)
        }
    }
    
    func waitForTask(_ taskId: String) {
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

            do {
                try self.getXMLFields(data!, getFields: [
                    "vim:CreateFilterResponse/vim:returnval"
                    ])
            } catch let err as NSError {
                self.errorHandler(err)
                return
            }
        }
    }
    
    func pollForUpdates(_ callback: @escaping (_ progress: Int, _ status: String) -> Void) {
        self.doRequest(
            "<WaitForUpdates xmlns=\"urn:internalvim25\">" +
                "<_this type=\"PropertyCollector\">\(self.propertyCollectorName)</_this>" +
                "<version>\(self.lastUpdateVersion.htmlEncode())</version>" +
            "</WaitForUpdates>"
        ) { (data, response, error) -> Void in
            if let err = error {
                if err.code == -1001 { //time out
                    self.pollForUpdates(callback)
                    return
                } else {
                    self.errorHandler(err)
                    return
                }
            }

            do {
                let xml = try self.processXML(data!)
                let versionNode = try xml.body.nodes(forXPath: "vim:WaitForUpdatesResponse/vim:returnval/vim:version")
                self.lastUpdateVersion = versionNode[0].stringValue!

                let filterSets = try xml.body.nodes(forXPath: "vim:WaitForUpdatesResponse/vim:returnval/vim:filterSet")
                for filterSet in filterSets {
                    let filterNode = try filterSet.nodes(forXPath: "vim:filter")
                    let propertyFilterId = filterNode[0].stringValue!

                    let vmSet = try filterSet.nodes(forXPath: "vim:objectSet[vim:obj/@type = \"VirtualMachine\"]")
                    if vmSet.count > 0 {
                        try self.updateVirtualMachines(vmSet)
                    }

                    let taskSet = try filterSet.nodes(forXPath: "vim:objectSet[vim:obj/@type = \"Task\"]")
                    if taskSet.count > 0 {
                        try self.updateTask(taskSet, filterId: propertyFilterId, callback: callback)
                    }
                }
            } catch let err as NSError {
                self.errorHandler(err)
                return
            }

            self.pollForUpdates(callback)
        }
    }

    func powerOffVM(_ vmId: String) {
        self.doRequest(
            "<PowerOffVM_Task xmlns=\"urn:internalvim25\">" +
                "<_this type=\"VirtualMachine\">\(vmId.htmlEncode())</_this>" +
            "</PowerOffVM_Task>"
        ) { (data, response, error) -> Void in
            if let err = error {
                self.errorHandler(err)
                return
            }

            let results : [String]
            do {
                results = try self.getXMLFields(data!, getFields: [
                    "vim:PowerOffVM_TaskResponse/vim:returnval"
                    ])
            } catch let err as NSError {
                self.errorHandler(err)
                return
            }

            let task = results[0]
            self.waitForTask(task)
        }
    }

    func resetVM(_ vmId: String) {
        self.doRequest(
            "<ResetVM_Task xmlns=\"urn:internalvim25\">" +
                "<_this type=\"VirtualMachine\">\(vmId.htmlEncode())</_this>" +
            "</ResetVM_Task>"
        ) { (data, response, error) -> Void in
            if let err = error {
                self.errorHandler(err)
                return
            }
            
            let results : [String]
            do {
                results = try self.getXMLFields(data!, getFields: [
                    "vim:ResetVM_TaskResponse/vim:returnval"
                    ])
            } catch let err as NSError {
                self.errorHandler(err)
                return
            }
            
            let task = results[0]
            self.waitForTask(task)
        }
    }
    
    func getVMScreenshot(_ vmId: String, callback: @escaping (_ imageData: Data) -> Void) {
        var urlRequest = URLRequest(url: URL(string: "https://\(self.host)/screen?id=\(vmId.urlEncode())")!)
        urlRequest.httpMethod = "GET"
        
        let base64creds = "\(self.username):\(self.password)".data(using: String.Encoding.utf8)?.base64EncodedData(options: NSData.Base64EncodingOptions(rawValue: 0))
        urlRequest.addValue("Basic \(base64creds)", forHTTPHeaderField: "Authorization")
        
        httpSession.dataTask(with: urlRequest, completionHandler: { (data, response, error) -> Void in
            if let imageData = data {
                DispatchQueue.main.async {
                    callback(imageData)
                }
            }
        }) .resume()
    }


    func updateTask(_ objSets: [XMLNode], filterId: String, callback: (_ progress: Int, _ status: String) -> Void) throws -> Void {
        for objSet in objSets {
            let objNode = try objSet.nodes(forXPath: "vim:obj")
            guard objNode.count > 0 else {
                throw NSError(domain: "myapp", code: VMError.responseParseError.rawValue, userInfo: nil)
            }
/*
            guard let taskId = objNode[0].stringValue else {
                throw NSError(domain: "myapp", code: VMError.ResponseParseError.rawValue, userInfo: nil)
            }
*/
            let changeSets = try objSet.nodes(forXPath: "vim:changeSet")
            var progress = -1
            var status = ""
            for changeSet in changeSets {
                let nameNode = try changeSet.nodes(forXPath: "vim:name")
                guard let name = nameNode[0].stringValue else {
                    throw NSError(domain: "myapp", code: VMError.responseParseError.rawValue, userInfo: nil)
                }

                if name == "info.progress" {
                    let valNode = try changeSet.nodes(forXPath: "vim:val")
                    if valNode.count > 0 && valNode[0].stringValue != nil {
                        let progressStr = valNode[0].stringValue!
                        if let progressInt = Int(progressStr) {
                            progress = progressInt
                        }
                    }
                }

                if name == "info.state" {
                    let valNode = try changeSet.nodes(forXPath: "vim:val")
                    if valNode.count > 0 && valNode[0].stringValue != nil {
                        status = valNode[0].stringValue!
                    }
                }
            }
            
            if status != "running" {
                progress = 100
                finishTask(filterId)
            }
            
            if progress >= 0 {
                callback(progress, status)
            }
        }
    }

    func finishTask(_ propertyFilterId: String) {
        self.doRequest(
            "<DestroyPropertyFilter xmlns=\"urn:internalvim25\">" +
                "<_this type=\"PropertyFilter\">\(propertyFilterId.htmlEncode())</_this>" +
            "</DestroyPropertyFilter>"
        ) { (data, response, error) -> Void in
            if let err = error {
                self.errorHandler(err)
                return
            }

            do {
                try self.getXMLFields(data!, getFields: [
                    "vim:DestroyPropertyFilterResponse"
                    ])
            } catch let err as NSError {
                if let detail = err.userInfo["detail"] as? String {
                    if detail == "ManagedObjectNotFoundFault" {
                        return
                    }
                }
                self.errorHandler(err)
                return
            }
        }

    }
    
    func updateVirtualMachines(_ objSets: [XMLNode]) throws -> Void {
        var dirty = false
        for objSet in objSets {
            //print(objSet)
            let objNode = try objSet.nodes(forXPath: "vim:obj")
            let vmId = objNode[0].stringValue!
            
            let changeSets = try objSet.nodes(forXPath: "vim:changeSet")
            for changeSet in changeSets {
                let nameNode = try changeSet.nodes(forXPath: "vim:name")
                let name = nameNode[0].stringValue!

                let valNode = try changeSet.nodes(forXPath: "vim:val")
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
        //print(self.vmList)
        if (dirty) {
            self.vmUpdateCallback!(self.vmList)
        }
    }
    
    func getVMs(_ vmUpdateCallback: @escaping (_ virtualMachines: [String: [String: String]]) -> Void) {
        self.vmUpdateCallback = vmUpdateCallback

        self.doRequest(
            "<CreateContainerView xmlns=\"urn:internalvim25\">" +
                "<_this type=\"ViewManager\">ViewManager</_this>" +
                "<container type=\"Folder\">\(self.rootFolderName.htmlEncode())</container>" +
                "<type>VirtualMachine</type>" +
                "<recursive>true</recursive>" +
            "</CreateContainerView>"
        ) { (data, response, error) -> Void in
            if let err = error {
                self.errorHandler(err)
                return
            }

            let results : [String]
            do {
                results = try self.getXMLFields(data!, getFields: [
                    "vim:CreateContainerViewResponse/vim:returnval"
                    ])
            } catch let err as NSError {
                self.errorHandler(err)
                return
            }

            let containerView = results[0]
            
            self.doRequest(
                "<RetrievePropertiesEx xmlns=\"urn:internalvim25\">" +
                    "<_this type=\"PropertyCollector\">\(self.propertyCollectorName)</_this>" +
                    "<specSet>" +
                        "<propSet>" +
                            "<type>ContainerView</type>" +
                            "<all>false</all>" +
                            "<pathSet>view</pathSet>" +
                        "</propSet>" +
                        "<objectSet>" +
                            "<obj type=\"ContainerView\">\(containerView.htmlEncode())</obj>" +
                            "<skip>false</skip>" +
                        "</objectSet>" +
                    "</specSet>" +
                    "<options></options>" +
                "</RetrievePropertiesEx>"
            ) { (data, response, error) -> Void in
                
                if let err = error {
                    self.errorHandler(err)
                    return
                }

                var xmlResponse = ""

                do {
                    let xml = try self.processXML(data!)
                    xmlResponse +=
                        "<CreateFilter xmlns=\"urn:internalvim25\">" +
                                "<_this type=\"PropertyCollector\">\(self.propertyCollectorName)</_this>" +
                                "<spec xsi:type=\"PropertyFilterSpec\">" +
                                    "<propSet xsi:type=\"PropertySpec\">" +
                                        "<type>VirtualMachine</type>" +
                                        "<pathSet>name</pathSet>" +
                                        "<pathSet>runtime.powerState</pathSet>" +
                                        "<pathSet>guest.ipAddress</pathSet>" +
                                    "</propSet>"

                    let vmNodes = try xml.body.nodes(forXPath: "//*[name()='val']/*[name()='ManagedObjectReference']")
                    for vmNode in vmNodes {
                        let vmId = vmNode.stringValue!
                        xmlResponse +=
                                    "<objectSet xsi:type=\"ObjectSpec\">" +
                                        "<obj type=\"VirtualMachine\">\(vmId.htmlEncode())</obj>" +
                                    "</objectSet>"
                    }

                    xmlResponse = xmlResponse +
                            "</spec>" +
                            "<partialUpdates>0</partialUpdates>" +
                        "</CreateFilter>"
                } catch let err as NSError {
                    self.errorHandler(err)
                    return
                }

                self.doRequest(xmlResponse) { (data, response, error) -> Void in
                    
                    if let err = error {
                        self.errorHandler(err)
                        return
                    }

                    do {
                        try self.getXMLFields(data!, getFields: [
                            "vim:CreateFilterResponse/vim:returnval"
                            ])
                    } catch let err as NSError {
                        self.errorHandler(err)
                        return
                    }

                }
            }
        }
    }
    
    func doRequest(_ request: String, callback: @escaping (_ data: Data?, _ response: URLResponse?, _ error: NSError?) -> Void) {
        
        var urlRequest = URLRequest(url: self.serverURL!)
        urlRequest.httpMethod = "POST"
        urlRequest.addValue("VMware VI Client/4.0.0", forHTTPHeaderField: "User-Agent")
        urlRequest.addValue("urn:internalvim25/\(self.apiVersion)", forHTTPHeaderField: "SOAPAction")
        urlRequest.httpBody = (
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" +
            "<env:Envelope xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\" xmlns:env=\"http://schemas.xmlsoap.org/soap/envelope/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">" +
                "<env:Body>\(request)</env:Body>" +
            "</env:Envelope>").data(using: String.Encoding.utf8)
        
        httpSession.dataTask(with: urlRequest, completionHandler: { (data, response, error) -> Void in
            if (!self.cancelled) {
                DispatchQueue.main.async {
                    callback(data, response, error as NSError?)
                }
            }
        }) .resume()
    }
    
    func processXML(_ data: Data) throws -> (doc: XMLDocument, body: XMLNode) {
        let xml = try XMLDocument(data: data, options: 0)
        let ns = XMLElement.namespace(withName: "vim", stringValue: "urn:internalvim25")
        xml.rootElement()!.addNamespace(ns as! XMLNode)
        
        let soapBody = try xml.nodes(forXPath: "/soapenv:Envelope/soapenv:Body")
        guard soapBody.count > 0 else {
            throw NSError(domain: "myapp", code: VMError.responseParseError.rawValue, userInfo: nil)
        }
        
        let fault = try soapBody[0].nodes(forXPath: "soapenv:Fault")
        guard fault.count == 0 else {
            var dict = [AnyHashable: Any]()
            let detailNode = try fault[0].nodes(forXPath: "detail")
            if detailNode.count > 0 && detailNode[0].children != nil && detailNode[0].children!.count > 0 {
                if let name = detailNode[0].children![0].name {
                    if name == "InvalidLoginFault" {
                        throw NSError(domain: "myapp", code: VMError.invalidLoginFault.rawValue, userInfo: nil)
                    } else {
                        dict["detail"] = name
                    }
                }
            }
            
            let faultcodeNode = try fault[0].nodes(forXPath: "faultcode")
            let faultstringNode = try fault[0].nodes(forXPath: "faultstring")

            if faultcodeNode.count > 0 {
                dict["faultcode"] = faultcodeNode[0].stringValue
            }
            if faultstringNode.count > 0 {
                dict["faultstring"] = faultstringNode[0].stringValue
            }
            if detailNode.count > 0 {
                dict["detailXML"] = detailNode[0].xmlString
            }
            throw NSError(domain: "myapp", code: VMError.unknownError.rawValue, userInfo: dict)
        }
        
        return (xml, soapBody[0])
    }
    
    func getXMLFields(_ data: Data, getFields: [String]) throws -> [String] {
        let xml = try processXML(data)
        var result = [String]()
        for xpath in getFields {
            let nodes = try xml.body.nodes(forXPath: xpath)
            guard nodes.count > 0 && nodes[0].stringValue != nil else {
                throw NSError(domain: "myapp", code: VMError.responseParseError.rawValue, userInfo: nil)
            }
            result.append(nodes[0].stringValue!)
        }
        
        return result
    }
    
    func cancel() {
        cancelled = true
    }
}

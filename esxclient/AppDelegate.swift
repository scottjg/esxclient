//
//  AppDelegate.swift
//  esxclient
//
//  Created by Scott Goldman on 4/7/16.
//  Copyright © 2016 scottjg. All rights reserved.
//

import Cocoa

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate, NSStreamDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate {

    @IBOutlet weak var window: NSWindow!
    @IBOutlet weak var sidebarList: NSOutlineView!
    @IBOutlet weak var vmNameField: NSTextField!
    @IBOutlet weak var vmStatusField: NSTextField!
    @IBOutlet weak var vmScreenshotView: NSImageView!
    @IBOutlet weak var viewConsoleButton: NSButton!
    @IBOutlet weak var powerOnButton: NSButton!
    @IBOutlet weak var powerOffButton: NSButton!
    @IBOutlet weak var progressCircle: NSProgressIndicator!
    var vmwareApi : VMwareApiClient?
    var vmwareMksVncProxy: VMwareMksVncProxy?
    var n = 0
    var vmList = [[String: String]]()
    var listHeader = [String: String]()

    override init() {
        var loading = [String: String]()
        loading["name"] = "Loading..."
        vmList.append(loading)

        listHeader["header"] = "Virtual Machines"
    }
    
    @IBAction func viewConsoleButtonClicked(sender: AnyObject) {
        let row = self.sidebarList.selectedRow
        if row > 0 {
            let vm = vmList[row - 1]
            let id = vm["id"]
            if id != nil {
                self.vmwareApi?.acquireMksTicket(id!) { (ticket, cfgFile, port, sslThumbprint) -> Void in
                    
                    self.vmwareMksVncProxy = VMwareMksVncProxy(host: self.vmwareApi!.host, ticket: ticket, cfgFile: cfgFile, port: port, sslThumbprint: sslThumbprint)
                    
                    self.vmwareMksVncProxy!.setupVncProxyServerPort() { (port) -> Void in
                        dispatch_async(dispatch_get_main_queue()) {
                            NSWorkspace.sharedWorkspace().openURL(NSURL(string: "vnc://abc:123@localhost:\(port)")!)
                        }
                    }
                }
            }
            
        }
    }

    @IBAction func sidebarAction(sender: AnyObject) {
        let row = self.sidebarList.selectedRow
        if row > 0 {
            let vm = vmList[row - 1]
            let id = vm["id"]
            if id != nil {
                vmNameField!.stringValue = vm["name"]!
                vmStatusField!.stringValue = vm["runtime.powerState"]!
                viewConsoleButton!.enabled = (vm["runtime.powerState"]! == "poweredOn")
                powerOnButton!.enabled = !viewConsoleButton!.enabled
                powerOffButton!.enabled = viewConsoleButton!.enabled
                self.vmwareApi?.getVMScreenshot(id!) { (screenshotData) -> Void in
                    dispatch_async(dispatch_get_main_queue()) {
                        self.vmScreenshotView.image = NSImage(data: screenshotData)
                    }
                }
            }
        } else {
            viewConsoleButton!.enabled = false
            powerOnButton!.enabled = false
            powerOffButton!.enabled = false
        }
        
    }

    @IBAction func powerOnButtonClick(sender: AnyObject) {
        let row = self.sidebarList.selectedRow
        if row > 0 {
            let vm = vmList[row - 1]
            let id = vm["id"]
            if id != nil {
                self.progressCircle?.doubleValue = 1.0
                self.progressCircle.hidden = false
                vmwareApi?.powerOnVM(id!) { (progress, status) -> Void in
                    print(progress)
                    dispatch_async(dispatch_get_main_queue()) {
                        self.progressCircle?.doubleValue = Double(progress > 0 ? progress : 1)
                        self.progressCircle.hidden = (progress == 100)
                    }
                    
                    if (status != "running") {
                        self.vmwareApi?.getVMs() { (virtualMachines) -> Void in
                            for vm in virtualMachines {
                                print(vm)
                            }
                            dispatch_async(dispatch_get_main_queue()) {
                                self.vmList = virtualMachines
                                let i = self.sidebarList.selectedRow
                                self.sidebarList.reloadData()
                                self.sidebarList.selectRowIndexes(NSIndexSet(index: i), byExtendingSelection: false)
                                self.sidebarAction(self)
                            }
                        }
                    }
                }
            }
        }
    }
    
    @IBAction func powerOffButtonClick(sender: AnyObject) {
        let row = self.sidebarList.selectedRow
        if row > 0 {
            let vm = vmList[row - 1]
            let id = vm["id"]
            if id != nil {
                self.progressCircle?.doubleValue = 1.0
                self.progressCircle.hidden = false
                vmwareApi?.powerOffVM(id!) { (progress, status) -> Void in
                    print(progress)
                    dispatch_async(dispatch_get_main_queue()) {
                        self.progressCircle?.doubleValue = Double(progress > 0 ? progress : 1)
                        self.progressCircle.hidden = (progress == 100)
                    }
                    
                    if (status != "running") {
                        self.vmwareApi?.getVMs() { (virtualMachines) -> Void in
                            for vm in virtualMachines {
                                print(vm)
                            }
                            dispatch_async(dispatch_get_main_queue()) {
                                self.vmList = virtualMachines
                                let i = self.sidebarList.selectedRow
                                self.sidebarList.reloadData()
                                self.sidebarList.selectRowIndexes(NSIndexSet(index: i), byExtendingSelection: false)
                                self.sidebarAction(self)
                            }
                        }
                    }
                }
            }
        }
    }

    func outlineView(outlineView: NSOutlineView, child index: Int, ofItem item: AnyObject?) -> AnyObject {
        var info = [String: String]()

        if item == nil {
            if index == 0 {
                return listHeader
            } else {
                info = vmList[index - 1]
            }
        }
        
        return info
    }
    
    func outlineView(outlineView: NSOutlineView, isItemExpandable item: AnyObject) -> Bool {
        return false
    }
    func outlineView(outlineView: NSOutlineView, numberOfChildrenOfItem item: AnyObject?) -> Int {
        return vmList.count + 1
    }
    func outlineView(outlineView: NSOutlineView, objectValueForTableColumn tableColumn: NSTableColumn?, byItem item: AnyObject?) -> AnyObject? {
        return item
    }

    func outlineView(outlineView: NSOutlineView, setObjectValue object: AnyObject?, forTableColumn tableColumn: NSTableColumn?, byItem item: AnyObject?) {
        
    }

    func outlineView(outlineView: NSOutlineView, dataCellForTableColumn tableColumn: NSTableColumn?, tem item: AnyObject) -> NSCell? {
        return nil
    }

    func outlineView(outlineView: NSOutlineView,
                     viewForTableColumn tableColumn: NSTableColumn?,
                                        item: AnyObject) -> NSView? {
        var v : NSTableCellView
        /*
        if n == 0 {
            v = outlineView.makeViewWithIdentifier("HeaderCell", owner: self) as! NSTableCellView
            if let tf = v.textField {
                tf.stringValue = "Virtual Machines" as! String
            }
        } else {
            v = outlineView.makeViewWithIdentifier("DataCell", owner: self) as! NSTableCellView
            if let tf = v.textField {
                tf.stringValue = item as! String
            }
        }
        n = n + 1
        */
        
        let info = item as! [String: String]
        if (info["header"] != nil) {
            v = outlineView.makeViewWithIdentifier("HeaderCell", owner: self) as! NSTableCellView
            if let tf = v.textField {
                tf.stringValue = info["header"]!
            }
        } else {
            v = outlineView.makeViewWithIdentifier("DataCell", owner: self) as! NSTableCellView
            if let tf = v.textField {
                tf.stringValue = info["name"]!
            }
        }
        
        return v
    }
    
    func outlineView(outlineView: NSOutlineView, isGroupItem item: AnyObject) -> Bool {
        let info = item as! [String: String]
        if (info["header"] != nil) {
            return true
        } else {
            return false
        }
    }
    
    func outlineView(outlineView: NSOutlineView, shouldSelectItem item: AnyObject) -> Bool {
        let info = item as! [String: String]
        return (info["id"] != nil)
    }

    func applicationDidFinishLaunching(aNotification: NSNotification) {
        let host = "172.16.21.33"
        let username = "root"
        let password = "passworD1"

        //let host = "10.0.1.26"
        //let username = "root"
        //let password = "hello123"
        
        //let host = "10.0.1.29"
        //let username = "VSPHERE.LOCAL\\scottjg"
        //let password = "Hello123!"

        self.vmwareApi = VMwareApiClient(username: username, password: password, host: host)

        self.vmwareApi?.login() {
            self.vmwareApi?.getVMs() { (virtualMachines) -> Void in
                for vm in virtualMachines {
                    print(vm)
                }
                dispatch_async(dispatch_get_main_queue()) {
                    self.vmList = virtualMachines
                    self.sidebarList.reloadData()
                }
            }
            /*
            self.vmwareApi?.acquireMksTicket("114") { (ticket, cfgFile, port, sslThumbprint) -> Void in
                
                self.vmwareMksVncProxy = VMwareMksVncProxy(host: host, ticket: ticket, cfgFile: cfgFile, port: port, sslThumbprint: sslThumbprint)
                
                self.vmwareMksVncProxy!.setupVncProxyServerPort() { (port) -> Void in
                        NSWorkspace.sharedWorkspace().openURL(NSURL(string: "vnc://abc:123@localhost:\(port)")!)
                }
            }
            */
        }
    }

    func applicationWillTerminate(aNotification: NSNotification) {
        // Insert code here to tear down your application
    }
}

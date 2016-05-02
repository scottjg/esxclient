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
    @IBOutlet weak var vmGuestIPField: NSTextField!
    @IBOutlet weak var vmScreenshotView: NSImageView!
    @IBOutlet weak var viewConsoleButton: NSButton!
    @IBOutlet weak var powerOnButton: NSButton!
    @IBOutlet weak var powerOffButton: NSButton!
    @IBOutlet weak var progressCircle: NSProgressIndicator!

    @IBOutlet weak var loginWindow: NSWindow!
    @IBOutlet weak var hostField: NSTextField!
    @IBOutlet weak var usernameField: NSTextField!
    @IBOutlet weak var passwordField: NSTextField!
    @IBOutlet weak var loginProgressSpinner: NSProgressIndicator!
    @IBOutlet weak var loginImage: NSImageView!
    @IBOutlet weak var connectButton: NSButton!
    
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
    
    override func controlTextDidChange(obj: NSNotification) {
        if self.hostField.stringValue != "" && self.usernameField.stringValue != "" && self.passwordField.stringValue != "" {
            
            self.connectButton.enabled = true
        } else {
            self.connectButton.enabled = false
        }

    }

    @IBAction func connectLoginButtonClicked(sender: AnyObject) {
        self.connectButton.enabled = false
        self.loginImage.hidden = true
        self.loginProgressSpinner.startAnimation(self)
        
        self.vmwareApi = VMwareApiClient(username: self.usernameField.stringValue, password: self.passwordField.stringValue, host: self.hostField.stringValue)

        self.vmwareApi?.login() { (error) -> Void in
            if let err = error {
                dispatch_async(dispatch_get_main_queue()) {
                    self.connectButton.enabled = true
                    self.loginImage.hidden = false
                    self.loginProgressSpinner.stopAnimation(self)
                
                    let alert = NSAlert(error: err)
                    alert.runModal()
                }
                return
            }
            dispatch_async(dispatch_get_main_queue()) {
                self.loginWindow.orderOut(self)
                self.window.makeKeyAndOrderFront(self)
            }
            self.vmwareApi?.pollForUpdates() { (progress, status) -> Void in
                print(progress)
                print(status)
            }
            
            self.vmwareApi?.getVMs() { (virtualMachines) -> Void in
                dispatch_async(dispatch_get_main_queue()) {
                    var vmIdSelected = ""
                    if self.sidebarList.selectedRow >= 1 {
                        vmIdSelected = self.vmList[self.sidebarList.selectedRow - 1]["id"]!
                    }
                    var newSelectedRow = -1
                    var currRow = 1
                    self.vmList = []
                    for vm in virtualMachines.values {
                        print(vm)
                        self.vmList.append(vm)
                        if vm["id"] == vmIdSelected {
                            newSelectedRow = currRow
                        }
                        currRow += 1
                    }
                    self.sidebarList.reloadData()
                    self.sidebarList.selectRowIndexes(NSIndexSet(index: newSelectedRow), byExtendingSelection: false)
                    self.sidebarAction(self)
                }
            }
        }
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
                vmGuestIPField!.stringValue = vm["guest.ipAddress"]!
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
        //let host = "172.16.21.33"
        //let username = "root"
        //let password = "passworD1"
        
        //let host = "10.0.1.26"
        self.hostField.stringValue = "10.0.1.39"
        self.usernameField.stringValue = "root"
        self.passwordField.stringValue = "hello123"
        
        //let host = "10.0.1.29"
        //let username = "VSPHERE.LOCAL\\scottjg"
        //let password = "Hello123!"
        
        self.connectButton.enabled = true
        
    }

    func applicationWillTerminate(aNotification: NSNotification) {
        // Insert code here to tear down your application
    }
    
    
    func shakeLoginWindow() {
        let numberOfShakes:Int = 8
        let durationOfShake:Float = 0.5
        let vigourOfShake:Float = 0.05
        
        let frame:CGRect = (self.loginWindow?.frame)!
        let shakeAnimation = CAKeyframeAnimation()
        
        let shakePath = CGPathCreateMutable()
        CGPathMoveToPoint(shakePath, nil, NSMinX(frame), NSMinY(frame))
        
        for _ in 1...numberOfShakes{
            CGPathAddLineToPoint(shakePath, nil, NSMinX(frame) - frame.size.width * CGFloat(vigourOfShake), NSMinY(frame))
            CGPathAddLineToPoint(shakePath, nil, NSMinX(frame) + frame.size.width * CGFloat(vigourOfShake), NSMinY(frame))
        }
        
        CGPathCloseSubpath(shakePath)
        shakeAnimation.path = shakePath
        shakeAnimation.duration = CFTimeInterval(durationOfShake)
        self.loginWindow.animations = ["frameOrigin":shakeAnimation]
        self.loginWindow.animator().setFrameOrigin(self.loginWindow.frame.origin)
    }
}

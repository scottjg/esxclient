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
    @IBOutlet weak var resetButton: NSButton!
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
    var loggedIn = false
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
        
        self.vmwareApi = VMwareApiClient(
            username: self.usernameField.stringValue,
            password: self.passwordField.stringValue,
            host: self.hostField.stringValue,
            errorHandler: { (error) -> Void in
                self.logout()
                let alert = NSAlert(error: error)
                alert.runModal()
            },
            updateHandler: { (virtualMachines) -> Void in
                if (!self.loggedIn) {
                    self.finishLogin()
                }
                var vmIdSelected = ""
                if self.sidebarList.selectedRow >= 1 {
                    vmIdSelected = self.vmList[self.sidebarList.selectedRow - 1]["id"]!
                }
                var newSelectedRow = -1
                var currRow = 1
                self.vmList = []
                for vm in virtualMachines.values {
                    //print(vm)
                    self.vmList.append(vm)
                    if vm["id"] == vmIdSelected {
                        newSelectedRow = currRow
                    }
                    currRow += 1
                }
                
                if newSelectedRow < 1 {
                    newSelectedRow = 1
                }
                self.sidebarList.reloadData()
                self.sidebarList.selectRowIndexes(NSIndexSet(index: newSelectedRow), byExtendingSelection: false)
                self.sidebarAction(self)

            },
            updateProgress: { (progressPercent, status) -> Void in
                self.progressCircle?.doubleValue = Double(progressPercent > 0 ? progressPercent : 1)
                self.progressCircle.hidden = (progressPercent == 100)
            }
        )

        self.vmwareApi!.startPollingForUpdates()
    }
    
    func finishLogin() {
        self.loginWindow.orderOut(self)
        self.window.title = self.vmwareApi!.title()
        self.window.makeKeyAndOrderFront(self)
    }
    
    func logout() {
        self.vmwareApi?.cancel()
        self.window.orderOut(self)

        self.connectButton.enabled = true
        self.loginImage.hidden = false
        self.loginProgressSpinner.stopAnimation(self)
        self.loginWindow.makeKeyAndOrderFront(self)
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
                            //print("connect to port \(port)")
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
                resetButton!.enabled = powerOffButton!.enabled
                self.vmwareApi?.getVMScreenshot(id!) { (screenshotData) -> Void in
                    self.vmScreenshotView.image = NSImage(data: screenshotData)
                }
            }
        } else {
            viewConsoleButton!.enabled = false
            powerOnButton!.enabled = false
            powerOffButton!.enabled = false
            resetButton!.enabled = false
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
                vmwareApi?.powerOnVM(id!)
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
                vmwareApi?.powerOffVM(id!)
            }
        }
    }

    @IBAction func resetButtonClick(sender: AnyObject) {
        let row = self.sidebarList.selectedRow
        if row > 0 {
            let vm = vmList[row - 1]
            let id = vm["id"]
            if id != nil {
                self.progressCircle?.doubleValue = 1.0
                self.progressCircle.hidden = false
                vmwareApi?.resetVM(id!)
            }
        }
    }
    
    @IBAction func loginCancelButtonClick(sender: AnyObject) {
        NSApp!.terminate(sender)
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
        
        let info = item as! [String: String]
        if (info["header"] != nil) {
            v = outlineView.makeViewWithIdentifier("HeaderCell", owner: self) as! NSTableCellView
            if let tf = v.textField {
                tf.stringValue = info["header"]!
            }
        } else {
            if info["runtime.powerState"] != nil && info["runtime.powerState"]! == "poweredOn" {
                v = outlineView.makeViewWithIdentifier("OnCell", owner: self) as! NSTableCellView
                if let tf = v.textField {
                    tf.stringValue = info["name"]!
                }
            } else {
                v = outlineView.makeViewWithIdentifier("OffCell", owner: self) as! NSTableCellView
                if let tf = v.textField {
                    tf.stringValue = info["name"]!
                }
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
        self.loginWindow!.level = Int(CGWindowLevelForKey(.MaximumWindowLevelKey))

        //self.hostField.stringValue  = "172.16.21.33"
        //self.usernameField.stringValue = "root"
        //self.passwordField.stringValue = "passworD1"
        
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
    
    /*
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
    */
}

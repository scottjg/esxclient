//
//  AppDelegate.swift
//  esxclient
//
//  Created by Scott Goldman on 4/7/16.
//  Copyright © 2016 scottjg. All rights reserved.
//

import Cocoa

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate, StreamDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate {

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
    
    override func controlTextDidChange(_ obj: Notification) {
        if self.hostField.stringValue != "" && self.usernameField.stringValue != "" && self.passwordField.stringValue != "" {
            
            self.connectButton.isEnabled = true
        } else {
            self.connectButton.isEnabled = false
        }

    }

    @IBAction func connectLoginButtonClicked(_ sender: AnyObject) {
        self.connectButton.isEnabled = false
        self.loginImage.isHidden = true
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
                self.sidebarList.selectRowIndexes(IndexSet(integer: newSelectedRow), byExtendingSelection: false)
                self.sidebarAction(self)

            },
            updateProgress: { (progressPercent, status) -> Void in
                if progressPercent == 0 {
                    self.progressCircle?.doubleValue = 1
                } else if progressPercent == 100 {
                    self.progressCircle?.doubleValue = 100.0
                    DispatchQueue.main.async { self.progressCircle?.doubleValue = 0 }
                } else {
                    self.progressCircle?.doubleValue = Double(progressPercent)
                }
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

        self.connectButton.isEnabled = true
        self.loginImage.isHidden = false
        self.loginProgressSpinner.stopAnimation(self)
        self.loginWindow.makeKeyAndOrderFront(self)
    }

    @IBAction func viewConsoleButtonClicked(_ sender: AnyObject) {
        let row = self.sidebarList.selectedRow
        if row > 0 {
            let vm = vmList[row - 1]
            let id = vm["id"]
            if id != nil {
                self.vmwareApi?.acquireMksTicket(id!) { (ticket, cfgFile, port, sslThumbprint) -> Void in
                    
                    self.vmwareMksVncProxy = VMwareMksVncProxy(host: self.vmwareApi!.host, ticket: ticket, cfgFile: cfgFile, port: port, sslThumbprint: sslThumbprint)
                    
                    self.vmwareMksVncProxy!.setupVncProxyServerPort() { (port) -> Void in
                        DispatchQueue.main.async {
                            NSWorkspace.shared().open(URL(string: "vnc://abc:123@localhost:\(port)")!)
                            //print("connect to port \(port)")
                        }
                    }
                }
            }
            
        }
    }

    @IBAction func sidebarAction(_ sender: AnyObject) {
        let row = self.sidebarList.selectedRow
        if row > 0 {
            let vm = vmList[row - 1]
            let id = vm["id"]
            if id != nil {
                vmNameField!.stringValue = vm["name"]!
                vmStatusField!.stringValue = vm["runtime.powerState"]!
                vmGuestIPField!.stringValue = vm["guest.ipAddress"]!
                viewConsoleButton!.isEnabled = (vm["runtime.powerState"]! == "poweredOn")
                powerOnButton!.isEnabled = !viewConsoleButton!.isEnabled
                powerOffButton!.isEnabled = viewConsoleButton!.isEnabled
                resetButton!.isEnabled = powerOffButton!.isEnabled
                self.vmwareApi?.getVMScreenshot(id!) { (screenshotData) -> Void in
                    self.vmScreenshotView.image = NSImage(data: screenshotData)
                }
            }
        } else {
            viewConsoleButton!.isEnabled = false
            powerOnButton!.isEnabled = false
            powerOffButton!.isEnabled = false
            resetButton!.isEnabled = false
        }
    }

    @IBAction func powerOnButtonClick(_ sender: AnyObject) {
        let row = self.sidebarList.selectedRow
        if row > 0 {
            let vm = vmList[row - 1]
            let id = vm["id"]
            if id != nil {
                self.progressCircle?.doubleValue = 1.0
                self.progressCircle.isHidden = false
                vmwareApi?.powerOnVM(id!)
            }
        }
    }
    
    @IBAction func powerOffButtonClick(_ sender: AnyObject) {
        let row = self.sidebarList.selectedRow
        if row > 0 {
            let vm = vmList[row - 1]
            let id = vm["id"]
            if id != nil {
                self.progressCircle?.doubleValue = 1.0
                self.progressCircle.isHidden = false
                vmwareApi?.powerOffVM(id!)
            }
        }
    }

    @IBAction func resetButtonClick(_ sender: AnyObject) {
        let row = self.sidebarList.selectedRow
        if row > 0 {
            let vm = vmList[row - 1]
            let id = vm["id"]
            if id != nil {
                self.progressCircle?.doubleValue = 1.0
                self.progressCircle.isHidden = false
                vmwareApi?.resetVM(id!)
            }
        }
    }
    
    @IBAction func loginCancelButtonClick(_ sender: AnyObject) {
        NSApp!.terminate(sender)
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
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
    
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        return false
    }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        return vmList.count + 1
    }
    func outlineView(_ outlineView: NSOutlineView, objectValueFor tableColumn: NSTableColumn?, byItem item: Any?) -> Any? {
        return item
    }

    func outlineView(_ outlineView: NSOutlineView, setObjectValue object: Any?, for tableColumn: NSTableColumn?, byItem item: Any?) {
        
    }

    func outlineView(_ outlineView: NSOutlineView, dataCellFor tableColumn: NSTableColumn?, item: Any) -> NSCell? {
        return nil
    }

    func outlineView(_ outlineView: NSOutlineView,
                     viewFor tableColumn: NSTableColumn?,
                                        item: Any) -> NSView? {
        var v : NSTableCellView
        
        let info = item as! [String: String]
        if (info["header"] != nil) {
            v = outlineView.make(withIdentifier: "HeaderCell", owner: self) as! NSTableCellView
            if let tf = v.textField {
                tf.stringValue = info["header"]!
            }
        } else {
            if info["runtime.powerState"] != nil && info["runtime.powerState"]! == "poweredOn" {
                v = outlineView.make(withIdentifier: "OnCell", owner: self) as! NSTableCellView
                if let tf = v.textField {
                    tf.stringValue = info["name"]!
                }
            } else {
                v = outlineView.make(withIdentifier: "OffCell", owner: self) as! NSTableCellView
                if let tf = v.textField {
                    tf.stringValue = info["name"]!
                }
            }
        }
        
        return v
    }
    
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        let info = item as! [String: String]
        if (info["header"] != nil) {
            return true
        } else {
            return false
        }
    }
    
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        let info = item as! [String: String]
        return (info["id"] != nil)
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        self.loginWindow!.level = Int(CGWindowLevelForKey(.maximumWindow))
        
        self.connectButton.isEnabled = true
    }

    func applicationWillTerminate(_ aNotification: Notification) {
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

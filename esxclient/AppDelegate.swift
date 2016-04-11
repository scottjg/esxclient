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
    var vmwareApi : VMwareApiClient?
    var vmwareMksVncProxy: VMwareMksVncProxy?

    override init() {

    }

    func applicationDidFinishLaunching(aNotification: NSNotification) {
        let host = "172.16.21.33"
        self.vmwareApi = VMwareApiClient(username: "root", password: "passworD1", host: host)

        self.vmwareApi?.login() {
            self.vmwareApi?.acquireMksTicket("114") { (ticket, cfgFile, port, sslThumbprint) -> Void in
                
                self.vmwareMksVncProxy = VMwareMksVncProxy(host: host, ticket: ticket, cfgFile: cfgFile, port: port, sslThumbprint: sslThumbprint)
                
                self.vmwareMksVncProxy!.setupVncProxyServerPort() { (port) -> Void in
                        NSWorkspace.sharedWorkspace().openURL(NSURL(string: "vnc://abc:123@localhost:\(port)")!)
                }
            }
        }
    }

    func applicationWillTerminate(aNotification: NSNotification) {
        // Insert code here to tear down your application
    }
}

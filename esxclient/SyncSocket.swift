//
//  SyncSocket.swift
//  SyncSocket
//
//  Created by Scott Goldman on 5/18/16.
//  Copyright © 2016 scottjg. All rights reserved.
//

import Foundation
import Cocoa

class SyncSocket: NSObject, StreamDelegate {
    var inputStream: InputStream
    var outputStream: OutputStream
    var opened = false
    var lastError: NSError?

    var waitingForByteCount = 0
    var incomingLine = Data()
    var incomingData = Data()
    var pendingRead = false

    var outgoingData = Data()
    var pendingWrite = false
    
    var selfPtr: UnsafeMutablePointer<SyncSocket>
    var ssl: SSLContext?
    
    init(host: String, port: UInt16) {
        var readStream: Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?
        CFStreamCreatePairWithSocketToHost(nil, host as CFString!, UInt32(port), &readStream, &writeStream);

        self.inputStream = readStream!.takeRetainedValue()
        self.outputStream = writeStream!.takeRetainedValue()
        self.selfPtr = UnsafeMutablePointer<SyncSocket>.allocate(capacity: 1)
        super.init()
        selfPtr.initialize(to: self)
        
        self.inputStream.delegate = self
        self.outputStream.delegate = self
        self.inputStream.schedule(in: .main, forMode: RunLoopMode.commonModes)
        self.outputStream.schedule(in: .main, forMode: RunLoopMode.commonModes)
    }
    
    init(inputStream: InputStream, outputStream: OutputStream) {
        self.inputStream = inputStream
        self.outputStream = outputStream
        self.selfPtr = UnsafeMutablePointer<SyncSocket>.allocate(capacity: 1)
        super.init()
        selfPtr.initialize(to: self)
        
        self.inputStream.delegate = self
        self.outputStream.delegate = self
        self.inputStream.schedule(in: .main, forMode: RunLoopMode.defaultRunLoopMode)
        self.outputStream.schedule(in: .main, forMode: RunLoopMode.defaultRunLoopMode)
    }
    
    deinit {
        selfPtr.deallocate(capacity: 1)
    }
    
    func connect() throws {
        assert(opened == false)
        self.inputStream.open()
        self.outputStream.open()
        while !opened {
            pumpEventLoop()
            if let err = self.lastError {
                throw err
            }
        }
    }
    
    func close() {
        self.opened = false
        self.inputStream.close()
        self.outputStream.close()
        DispatchQueue.main.async {}
    }
    
    func pumpEventLoop() {
        assert(Thread.isMainThread)
        let event = NSApp.nextEvent(matching: NSEventMask.any, until: Date.distantFuture, inMode: RunLoopMode.defaultRunLoopMode, dequeue: true)
        if let e = event {
            NSApp.sendEvent(e)
            NSApp.updateWindows()
        }
    }
    
    func readLine(_ maxLength: Int?) throws -> String {
        //XXX reading one byte at a time, and yielding to the
        //    event loop every time is probably pretty slow.
        //    i was only expecting this to be used in really
        //    minimal control-path operations, so i didn't need
        //    to optimize. might be nice to fix this at some point
        while true {
            let buf = try self.read(1)
            if buf[0] == 0x0a { // '\n'
                break
            } else {
                self.incomingLine.append(buf, count: 1)
            }
            if let max = maxLength {
                if self.incomingLine.count > max {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EMSGSIZE), userInfo: [:])
                }
            }
        }
        
        guard let line = String(data: self.incomingLine, encoding: String.Encoding.utf8) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL), userInfo: [NSLocalizedDescriptionKey: "Line contained non UTF8 data"])
        }
        
        self.incomingLine = Data()
        return line
    }
    
    /*
    func readInt32() throws -> Int32 {
        let buf = try self.read(4)
        if NSHostByteOrder() == NS_LittleEndian {
            return Int32(buf[3]) |
                (Int32(buf[2]) >> 1 ) |
                (Int32(buf[1]) >> 2 ) |
                (Int32(buf[0]) >> 3)
        } else {
            return Int32(buf[0]) |
                (Int32(buf[1]) >> 1 ) |
                (Int32(buf[2]) >> 2 ) |
                (Int32(buf[3]) >> 3)
        }
    }
    */
    func read(_ size: Int) throws -> [UInt8] {
        if let ssl = self.ssl {
            var buf : [UInt8] = Array(repeating: 0, count: size)
            var readSize: Int = 0
            let status = SSLRead(ssl, &buf, size, &readSize)
            if status != 0 {
                throw NSError(domain: kCFErrorDomainOSStatus as String, code: Int(status), userInfo: [:])
            }
            assert(readSize == size)
            return buf
        } else {
            return try self._read(size)
        }
    }
    
    func _read(_ size: Int) throws -> [UInt8] {
        if let err = self.lastError {
            throw err
        }
        
        assert(self.waitingForByteCount == 0)

        self.waitingForByteCount = size
        if self.incomingData.count >= self.waitingForByteCount {
            self.waitingForByteCount = 0
        } else if self.incomingData.count < self.waitingForByteCount {
            self.waitingForByteCount -= self.incomingData.count
        }
        
        if self.pendingRead || self.inputStream.hasBytesAvailable {
            pendingRead = false
            stream(self.inputStream, handle: Stream.Event.hasBytesAvailable)
        }
        
        while waitingForByteCount > 0 && self.lastError == nil {
            pumpEventLoop()
        }
        
        if let err = self.lastError {
            throw err
        }
        
        let data = incomingData.withUnsafeBytes {
            return [UInt8](UnsafeBufferPointer(start: $0, count: size))
        }

        incomingData.removeFirst(size)
        return data
    }
    
    func _write(_ data: [UInt8], length: Int = 0) throws {
        let size = length != 0 ? length : data.count
        if let err = self.lastError {
            throw err
        }
        
        //assert(self.outgoingData.count == 0)
        self.outgoingData.append(data, count: size)
        print("pending write is \(self.outgoingData.count) bytes")
        if self.outgoingData.count > size {
            // we don't want to keep recursing here if there's already
            // a loop in the stack that's waiting for the data to flush
            print("stopping write recursion")
            return
        }

        if pendingWrite || self.outputStream.hasSpaceAvailable {
            pendingWrite = false
            self.stream(self.outputStream, handle: Stream.Event.hasSpaceAvailable)
        }

        while outgoingData.count > 0 && self.lastError == nil {
            pumpEventLoop()
        }

        if let err = self.lastError {
            throw err
        }
    }
    
    func write(_ data: [UInt8], length: Int = 0) throws {
        let size = length != 0 ? length : data.count
        if let ssl = self.ssl {
            var written : Int = 0
            let status = SSLWrite(ssl, data, size, &written)
            if status != 0 {
                throw NSError(domain: kCFErrorDomainOSStatus as String, code: Int(status), userInfo: [:])
            }
            assert(written == size)
        } else {
            try self._write(data, length: size)
        }
    }

    func write(_ string: String) throws {
        assert(self.outgoingData.count == 0)
        try self.write(Array(string.utf8))
    }

    //func getFdFromStream(stream: NSInputStream) -> Int32 {
    //    let socketData = CFReadStreamCopyProperty(stream, kCFStreamPropertySocketNativeHandle) as! CFData;
    //    let handle = CFSocketNativeHandle(CFDataGetBytePtr(socketData).memory)

    //    return handle
    //}
    
    //func getSocket() {
    //    if self.socket < 0 {
    //        self.socket = getFdFromStream(self.inputStream)
    //
    //        //set non blocking
    //        let flags = fcntl(self.socket, F_GETFL);
    //        assert(flags >= 0)
    //        let newFlags = fcntl(self.socket, F_SETFL, flags | O_NONBLOCK)
    //        assert(newFlags >= 0)
    //    }
    //}
    
    
    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        if eventCode.contains(Stream.Event.openCompleted) {
            opened = true
        }
        
        if eventCode.contains(Stream.Event.errorOccurred) {
            saveError(nil)
            return
        }

        if eventCode.contains(Stream.Event.hasBytesAvailable) {
            if (self.waitingForByteCount > 0) {
                var buf = [UInt8](repeating: 0, count: (self.waitingForByteCount > 32768 ? 32768: self.waitingForByteCount))
                let size = self.inputStream.read(&buf, maxLength: buf.count)
                //print("read \(size)")
                if size > 0 {
                    self.incomingData.append(&buf, count: size)
                    waitingForByteCount -= size
                    assert(waitingForByteCount >= 0)
                } else if size < 0 {
                    saveError(nil)
                    return
                } else if size == 0 {
                    saveError(EIO)
                    return
                }
            } else {
                pendingRead = true
            }
        }
        
        if eventCode.contains(Stream.Event.hasSpaceAvailable) {
            if self.outgoingData.count > 0 {
                let data = self.outgoingData.withUnsafeBytes {
                    return [UInt8](UnsafeBufferPointer(start: $0, count: self.outgoingData.count))
                }

               let wrote = self.outputStream.write(data, maxLength: self.outgoingData.count)

                if wrote > 0 {
                    print("wrote \(wrote) bytes to \(self.inputStream)")
                    self.outgoingData.removeFirst(wrote)
                } else if wrote < 0 {
                    saveError(nil)
                    return
                } else if wrote == 0 {
                    saveError(EIO)
                    return
                }
            } else {
                pendingWrite = true
            }
        }

        // make sure to wake up the event loop in case we're pumping it.
        let event = NSEvent.otherEvent(with: NSApplicationDefined, location: NSPoint(x: 0.0, y: 0.0), modifierFlags: NSEventModifierFlags.init(rawValue: 0), timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)
        NSApp.postEvent(event!, atStart: false)
    }
    
    func saveError(_ err: NSError) {
        self.lastError = err
        DispatchQueue.main.async {}
    }

    func saveError(_ err: Int32?) {
        if let errNum = err {
            self.lastError = NSError(domain: NSPOSIXErrorDomain, code: Int(errNum), userInfo: [:])
        } else if let err = self.inputStream.streamError {
            self.lastError = err as NSError?
        } else if let err = self.outputStream.streamError {
            self.lastError = err as NSError?
        } else {
            self.lastError = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSYS), userInfo: [NSLocalizedDescriptionKey: "Unknown Error"])
        }
        print("saved error \(self.lastError)")
        DispatchQueue.main.async { }
    }
    
    func startSSL() throws {
        self.ssl = SSLCreateContext(kCFAllocatorDefault, SSLProtocolSide.clientSide, SSLConnectionType.streamType)
        guard let ssl = self.ssl else {
            fatalError("failed to create ssl context")
        }
        SSLSetSessionOption(ssl, SSLSessionOption.breakOnServerAuth, true)
        SSLSetIOFuncs(ssl, syncSocketSslReadCallback, syncSocketSslWriteCallback)
        SSLSetConnection(ssl, self.selfPtr)

        
        var r = SSLHandshake(ssl)
        if r == -9841 { //XXX we're supposed to verify the SSL cert here
            r = SSLHandshake(ssl)
        }
        
        if r != 0 {
            throw NSError(domain: kCFErrorDomainOSStatus as String, code: Int(r), userInfo: [:])
        }
    }
}


func syncSocketSslReadCallback(_ connection: SSLConnectionRef,
                     data: UnsafeMutableRawPointer,
                     dataLength: UnsafeMutablePointer<Int>) -> OSStatus {
    let delegate = UnsafeMutableRawPointer(mutating: connection).assumingMemoryBound(to: SyncSocket.self).pointee
    if delegate.inputStream.delegate! is SyncSocketProxy {
        return syncSocketProxySslReadCallback(connection, data: data, dataLength: dataLength)
    }

    
    let expectedReadSize = dataLength.pointee
    dataLength.pointee = 0
    do {
        //print("reading \(expectedReadSize) for ssl from \(delegate.inputStream)")
        //XXX really shouldn't need a copy here
        var buf = try delegate._read(expectedReadSize)
        assert(buf.count == expectedReadSize)
        data.copyBytes(from: &buf, count: buf.count)
        dataLength.pointee += buf.count
        //print("read.")
    } catch _ as NSError {
        return Int32(errSSLClosedGraceful)
    }
    
    return 0
}

func syncSocketSslWriteCallback(_ connection: SSLConnectionRef,
                      data: UnsafeRawPointer,
                      dataLength: UnsafeMutablePointer<Int>) -> OSStatus {
    let delegate = UnsafeMutableRawPointer(mutating: connection).assumingMemoryBound(to: SyncSocket.self).pointee
    if delegate.inputStream.delegate! is SyncSocketProxy {
        return syncSocketProxySslWriteCallback(connection, data: data, dataLength: dataLength)
    }

    //XXX unclear -- does this coercion make any copies?
    let buffer = UnsafeBufferPointer<UInt8>(start: data.assumingMemoryBound(to: UInt8.self), count: dataLength.pointee)
    let arr = Array(buffer)

    do {
        try delegate._write(arr)
    } catch _ as NSError {
        return Int32(errSSLClosedGraceful)
    }

    return 0
}

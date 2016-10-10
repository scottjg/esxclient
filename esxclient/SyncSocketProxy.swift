//
//  SyncSocketProxy.swift
//  esxclient
//
//  Created by Scott Goldman on 10/9/16.
//  Copyright © 2016 scottjg. All rights reserved.
//

import Foundation
import Cocoa

class SyncSocketProxy: NSObject, StreamDelegate {
    var socket1, socket2 : SyncSocket
    var eof = false
    var socket1Ptr, socket2Ptr: UnsafeMutablePointer<SyncSocket>
    var outgoingData1, outgoingData2 : Data

    init(socket1: SyncSocket, socket2: SyncSocket) {
        self.socket1 = socket1
        self.socket2 = socket2

        self.socket1Ptr = UnsafeMutablePointer<SyncSocket>.allocate(capacity: 1)
        self.socket2Ptr = UnsafeMutablePointer<SyncSocket>.allocate(capacity: 1)
        
        self.outgoingData1 = Data()
        self.outgoingData2 = Data()
        super.init()
        socket1Ptr.initialize(to: socket1)
        socket2Ptr.initialize(to: socket2)
    }

    deinit {
        socket1Ptr.deallocate(capacity: 1)
        socket2Ptr.deallocate(capacity: 1)
    }

    func proxyUntilHangup() {
        self.socket1.inputStream.delegate = self
        self.socket1.outputStream.delegate = self
        if let ssl = self.socket1.ssl {
            SSLSetIOFuncs(ssl, syncSocketProxySslReadCallback, syncSocketProxySslWriteCallback)
            SSLSetConnection(ssl, self.socket1Ptr)
        }

        self.socket2.inputStream.delegate = self
        self.socket2.outputStream.delegate = self
        if let ssl = self.socket2.ssl {
            SSLSetIOFuncs(ssl, syncSocketProxySslReadCallback, syncSocketProxySslWriteCallback)
            SSLSetConnection(ssl, self.socket2Ptr)
        }

        while (!eof) {
            socket1.pumpEventLoop()
        }
        
        self.socket1.close()
        self.socket2.close()
    }
    
    func queueWrite(socket: SyncSocket, buffer: UnsafeMutablePointer<UInt8>, length: Int) {
        if socket == self.socket1 {
            self.outgoingData1.append(buffer, count: length)
            if socket1.outputStream.hasSpaceAvailable {
                self.stream(self.socket1.outputStream, handle: Stream.Event.hasSpaceAvailable)
            }
        }

        if socket == self.socket2 {
            self.outgoingData2.append(buffer, count: length)
            if socket2.outputStream.hasSpaceAvailable {
                self.stream(self.socket2.outputStream, handle: Stream.Event.hasSpaceAvailable)
            }
        }
    }
    
    func flushSocketWithData(socket: OutputStream, data: inout Data) {
        if data.count == 0 {
            //print("no more data to flush")
            return
        }
        
        if !socket.hasSpaceAvailable {
            //print("no more space to flush data")
            return
        }
        
        let r = data.withUnsafeBytes { socket.write($0, maxLength: data.count) }
        if r <= 0 {
            eof = true
            return
        }
        
        //print("wrote \(r) bytes")
        data.removeFirst(r)
    }
    
    func flushSocket(socket: OutputStream) {
        if socket == self.socket1.outputStream {
            flushSocketWithData(socket: socket, data: &self.outgoingData1)
        } else {
            flushSocketWithData(socket: socket, data: &self.outgoingData2)
        }
    }
    
    func proxyDataFromSocket(srcStream: InputStream) {
        if !srcStream.hasBytesAvailable {
            //print("didn't have any bytes to read")
            return
        }

        let srcSslCtx, dstSslCtx : SSLContext?
        let dstSocket: SyncSocket

        if srcStream == self.socket1.inputStream {
            dstSslCtx = self.socket2.ssl
            dstSocket = self.socket2
            srcSslCtx = self.socket1.ssl
        } else {
            dstSslCtx = self.socket1.ssl
            dstSocket = self.socket1
            srcSslCtx = self.socket2.ssl
        }
        
        var buffer = Data(count: 32768)
        
        var bytesRead: Int = 0
        if let ssl = srcSslCtx {
            let r = buffer.withUnsafeMutableBytes {
                SSLRead(ssl, $0, buffer.count, &bytesRead)
            }
            
            if r < 0 {
                bytesRead = Int(r)
            }
        } else {
            bytesRead = buffer.withUnsafeMutableBytes {
                srcStream.read($0, maxLength: buffer.count)
            }
        }
        
        if bytesRead <= 0 {
            if bytesRead != Int(errSSLWouldBlock) {
                eof = true
            }
            return
        }
        
        //print("read \(bytesRead) bytes")
        
        var bytesWritten: Int = 0
        if let ssl = dstSslCtx {
            let _ = buffer.withUnsafeBytes { SSLWrite(ssl, $0, bytesRead, &bytesWritten) }
        } else {
            buffer.withUnsafeMutableBytes { queueWrite(socket: dstSocket, buffer: $0, length: bytesRead) }
            bytesWritten = bytesRead
        }
        
        if (bytesWritten < bytesRead) {
            eof = true
            return
        }
        
    }
    
    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        if eventCode.contains(Stream.Event.hasSpaceAvailable) {
            flushSocket(socket: aStream as! OutputStream)
        }

        
        if eventCode.contains(Stream.Event.errorOccurred) {
            eof = true
            return
        }

        if eventCode.contains(Stream.Event.hasBytesAvailable) {
            proxyDataFromSocket(srcStream: aStream as! InputStream)
        }
    }
}


func syncSocketProxySslReadCallback(_ connection: SSLConnectionRef,
                               data: UnsafeMutableRawPointer,
                               dataLength: UnsafeMutablePointer<Int>) -> OSStatus {
    let socket = UnsafeMutableRawPointer(mutating: connection).assumingMemoryBound(to: SyncSocket.self).pointee
    let dataPtr = UnsafeMutableRawPointer(mutating: data).assumingMemoryBound(to: UInt8.self)

    let expectedReadSize = dataLength.pointee
    dataLength.pointee = 0

    //print("reading \(expectedReadSize) for ssl from \(delegate.inputStream)")
    if socket.inputStream.hasBytesAvailable {
        let r = socket.inputStream.read(dataPtr, maxLength: expectedReadSize)
        if r <= 0 {
            return Int32(errSSLClosedGraceful)
        }
        
        dataLength.pointee = r
    }

    if dataLength.pointee < expectedReadSize {
        return Int32(errSSLWouldBlock)
    } else {
        return 0
    }
}

func syncSocketProxySslWriteCallback(_ connection: SSLConnectionRef,
                                data: UnsafeRawPointer,
                                dataLength: UnsafeMutablePointer<Int>) -> OSStatus {
    let socket = UnsafeMutableRawPointer(mutating: connection).assumingMemoryBound(to: SyncSocket.self).pointee
    let dataPtr = UnsafeMutableRawPointer(mutating: data).assumingMemoryBound(to: UInt8.self)

    
    let socketProxy = socket.inputStream.delegate as! SyncSocketProxy
    socketProxy.queueWrite(socket: socket, buffer: dataPtr, length: dataLength.pointee)
    
    return 0
}

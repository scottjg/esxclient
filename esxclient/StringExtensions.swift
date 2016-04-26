//
//  StringExtensions.swift
//  esxclient
//
//  Created by Scott Goldman on 4/7/16.
//  Copyright © 2016 scottjg. All rights reserved.
//

import Foundation

extension String {
    func htmlEncode() -> String {
        return self.stringByReplacingOccurrencesOfString("<", withString: "&lt;").stringByReplacingOccurrencesOfString(">", withString: "&gt;").stringByReplacingOccurrencesOfString("&", withString: "&amp;")
    }
    
    func urlEncode() -> String {
        return self.stringByAddingPercentEncodingWithAllowedCharacters(.URLQueryAllowedCharacterSet())!
    }
}

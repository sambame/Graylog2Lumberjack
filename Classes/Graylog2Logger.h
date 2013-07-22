//
//  Graylog2Logger.h
//  shakka.me
//
//  Created by Shay Erlichmen on 27/10/12.
//  Copyright (c) 2012 shakka.me. All rights reserved.
//

#import "DDLog.h"

@interface Graylog2Logger : DDAbstractLogger <DDLogger>

-(void)connectToServer:(NSString*)host;

-(id)init;
@end

//
//  Created by Ole Gammelgaard Poulsen on 02/10/14.
//  Copyright (c) 2014 SHAPE A/S. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>


@interface CellContainerView : NSView

@property(nonatomic, readonly) NSArray *containerViews;

- (id)initWithNumberOfContainers:(NSUInteger)numContainers;

@end
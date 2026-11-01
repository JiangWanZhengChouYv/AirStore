//
//  main.m
//  AirBox
//
//  Nothing happens here before the app starts: a guest is not taken over in this process any more, it
//  is started in the extension under PlugIns, so the list is the only thing this entry point has to
//  bring up.
//

#import <UIKit/UIKit.h>

int main(int argc, char *argv[])
{
    return UIApplicationMain(argc, argv, nil, @"AirBoxDelegate");
}

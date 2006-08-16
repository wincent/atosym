//
//  atosym.m
//  atosym
//  A quick hack thrown together while waiting for Apple to make atos(1) dSYM-compatible
//
//  Created by Wincent Colaiuta on 02/08/06.
//  Copyright Wincent Colaiuta 2006. All rights reserved.
//  $Id$

// system headers
#import <Foundation/Foundation.h>
#import <sys/param.h>               /* MAXPATHLEN */

#pragma mark Type definitions

typedef enum WOArchitectures {
    WOArchPPC,
    WOArchI386
} WOArchitectures;

#pragma mark Global variables

int         arch    = 0;
NSString    *dsym   = nil;
unsigned    offset  = 0;

@interface NSString (atosym)

- (unsigned)intOrHexIntValue;

@end

@implementation NSString (atosym)

- (unsigned)intOrHexIntValue
{
    unsigned returnValue = 0;
    NSScanner *scanner = [NSScanner scannerWithString:self];
    if ([scanner scanString:@"0x" intoString:NULL])
        [scanner scanHexInt:&returnValue];
    else
    {
        int intValue = [self intValue];
        if ((intValue != INT_MIN) && (intValue != INT_MAX) && intValue > 0)
            returnValue = (unsigned)intValue;
    }
    return returnValue;
}

@end

#pragma mark -
#pragma mark Functions

void show_usage (void)
{
    fprintf(stdout, "usage: atosym -d dSYM-file [-arch i386|ppc] [-o offset] [address ...]\n");
}

NSString *get_symbol_information (unsigned address)
{
    NSString *gdb = nil;
    if (arch == WOArchI386)
        gdb = @"/usr/libexec/gdb/gdb-i386-apple-darwin";
    else if (arch == WOArchPPC)
        gdb = @"/usr/libexec/gdb/gdb-powerpc-apple-darwin";
    
    const char *command = [[NSString stringWithFormat:@"info line *%#x", address + offset] UTF8String];
    char *template[MAXPATHLEN];
    strcpy((char *)template, "/tmp/atosym.XXXXXX");
    int temp = mkstemp((char *)template);
    if (temp == -1)
    {
        perror("mkstemp");
        return nil;
    }
    size_t wrote = write(temp, command, strlen(command));
    if (wrote == -1)
    {
        perror("write");
        return nil;
    }
    
    NSTask          *task       = [[NSTask alloc] init];
    NSPipe          *pipe       = [NSPipe pipe];
    NSFileHandle    *handle     = [pipe fileHandleForReading];
    NSArray         *arguments  = 
        [NSArray arrayWithObjects:@"--batch", @"--quiet", @"-x", [NSString stringWithUTF8String:(const char*)template], dsym, nil];
    
    [task setStandardOutput:pipe];
    [task setLaunchPath:gdb];
    [task setArguments:arguments];
    [task launch];
    
    NSData          *data       = [handle readDataToEndOfFile];
    [task release];
    return [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
}

int start_noninteractive_mode (NSArray *addresses)
{
    int             err         = EXIT_SUCCESS;
    NSEnumerator    *enumerator = [addresses objectEnumerator];
    NSNumber        *address    = nil;
    while ((address = [enumerator nextObject]))
    {
        NSString *symbol = get_symbol_information([address unsignedIntValue]);
        if (symbol)
            fprintf(stdout, "%s", [symbol UTF8String]);
        else
        {
            fprintf(stderr, "error: failed to get symbol information for address, %#x (offset: %#x)\n", [address unsignedIntValue], 
                    offset);
            err = EXIT_FAILURE;
        }
    }
    return err;
}

int start_interactive_mode (void)
{
    int err = EXIT_SUCCESS;
    fprintf(stdout, "Enter an address in hex, or quit to exit:\n");
    fprintf(stdout, "> ");
    unsigned int address;
    while (scanf("%x", &address))
    {
        NSString *symbol = get_symbol_information(address);
        if (symbol)
        {
            fprintf(stdout, "%s", [symbol UTF8String]);
            err = EXIT_SUCCESS;
        }
        else
        {
            fprintf(stderr, "error: failed to get symbol information for address, %#x (offset: %#x)\n", address, offset);
            err = EXIT_FAILURE;
        }
        fprintf(stdout, "> ");
    }
    return err;
}

int main (int argc, const char * argv[])
{
    NSAutoreleasePool * pool = [[NSAutoreleasePool alloc] init];
    int err = EXIT_FAILURE;

    NSUserDefaults  *defaults   = [NSUserDefaults standardUserDefaults];
    NSFileManager   *manager    = [NSFileManager defaultManager];
    
    NSString *file = [defaults stringForKey:@"d"];
    if (!file)
    {
        fprintf(stderr, "error: no dSYM-file specified\n");
        show_usage();
        goto Cleanup;
    }
    if (![manager fileExistsAtPath:file])
    {
        fprintf(stderr, "error: file \"%s\" does not exist\n", [file fileSystemRepresentation]);
        goto Cleanup;
    }
    dsym = [file retain]; // leak until exit
    
    NSString *architecture = [[defaults stringForKey:@"architecture"] lowercaseString];
    if (!architecture) architecture = @"i386";
    if ([architecture isEqualTo:@"i386"])
        arch = WOArchI386;
    else if ([architecture isEqualTo:@"ppc"])
        arch = WOArchPPC;
    else
    {
        fprintf(stderr, "error: unknown architecture, \"%s\"\n", [architecture UTF8String]);
        show_usage();
        goto Cleanup;
    }
    
    NSString *offsetString = [defaults stringForKey:@"offset"];
    if (offsetString)
    {
        offset = [offsetString intOrHexIntValue]; // will be zero on scanning failure
        if (offset == 0)
        {
            fprintf(stderr, "error: invalid offset \"%s\"\n", [offsetString UTF8String]);
            goto Cleanup;
        }
    }
    
    // all other args should be addresses, if no addresses enter interactive mode
    NSArray         *args       = [[NSProcessInfo processInfo] arguments];
    NSMutableArray  *addresses  = [NSMutableArray array];
    NSEnumerator    *enumerator = [args objectEnumerator];
    NSString        *string     = nil;
    [enumerator nextObject]; // skip first arg (invocation of atosym itself)
    while ((string = [enumerator nextObject]))
    {
        if ([string hasPrefix:@"-"])
        {
            [enumerator nextObject];    // skip this argument (the switch) and the following one too (its value)
            continue;
        }
        unsigned address = [string intOrHexIntValue];
        if (address == 0)
        {
            fprintf(stderr, "error: invalid address argument \"%s\"\n", [string UTF8String]);
            goto Cleanup;
        }
        else
            [addresses addObject:[NSNumber numberWithUnsignedInt:address]];
    }
    
    if ([addresses count] == 0)
        err = start_interactive_mode();
    else
        err = start_noninteractive_mode(addresses);
    
Cleanup:
    [pool release];
    return err;
}
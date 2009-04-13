//
//  atosym.m
//  atosym
//  A quick hack thrown together while waiting for Apple to make atos(1) dSYM-compatible
//  See http://wincent.com/a/products/atosym/ for more information
//
//  Created by Wincent Colaiuta on 02/08/06.
//  Copyright 2006 Wincent Colaiuta
//  All rights reserved.
//
//  Redistribution and use in source and binary forms, with or without
//  modification, are permitted provided that the following conditions
//  are met:
//     1. Redistributions of source code must retain the above copyright
//        notice, this list of conditions and the following disclaimer.
//     2. Redistributions in binary form must reproduce the above copyright
//        notice, this list of conditions and the following disclaimer in the
//        documentation and/or other materials provided with the distribution.
//     3. The name of the author may not be used to endorse or promote products
//        derived from this software without specific prior written permission.
//
//  THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
//  IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
//  OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
//  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
//  INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
//  NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
//  DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
//  THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
//  (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
//  THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//
//  $Id$

// system headers
#import <Foundation/Foundation.h>
#import <sys/param.h>               /* MAXPATHLEN */

#pragma mark Global variables

NSString    *arch       = nil;
NSString    *dsym       = nil;
unsigned    offset      = 0;
const char  *version    = "1.0.1";

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
    fprintf(stdout, "atosym version %s, Copyright 2006 Wincent Colaita.\n", version);
    fprintf(stdout, "usage: atosym -d dSYM-file [-arch i386|ppc] [-o offset] [address ...]\n");
}

NSString *get_symbol_information (unsigned address)
{
    const char *command = [[NSString stringWithFormat:@"info line *%#x", address - offset] UTF8String];
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
    NSArray         *arguments  = [NSArray arrayWithObjects:@"-arch", arch, @"--batch", @"--quiet", @"-x", 
        [NSString stringWithUTF8String:(const char*)template], dsym, nil];
    
    [task setStandardOutput:pipe];
    [task setLaunchPath:@"/usr/bin/gdb"];
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
    if (!architecture)
        arch = @"i386";
    else
        arch = [architecture retain]; // leak until exit
    
    NSString *offsetString = [defaults stringForKey:@"o"];
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

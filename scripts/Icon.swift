import AppKit
let destination = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
for size in [16,32,128,256,512] {
    for scale in [1,2] {
        let pixels = size*scale
        let rep = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:rep)
        let transform = NSAffineTransform(); transform.scale(by:CGFloat(pixels)/1024); transform.concat()
        NSColor(calibratedRed:0.13,green:0.20,blue:0.20,alpha:1).setFill()
        NSBezierPath(roundedRect:NSRect(x:64,y:64,width:896,height:896),xRadius:196,yRadius:196).fill()
        NSColor(calibratedRed:0.87,green:0.88,blue:0.82,alpha:1).setStroke()
        let frame = NSBezierPath(roundedRect:NSRect(x:260,y:270,width:504,height:484),xRadius:42,yRadius:42)
        frame.lineWidth = 30; frame.stroke()
        let bar = NSBezierPath(); bar.move(to:NSPoint(x:276,y:636)); bar.line(to:NSPoint(x:748,y:636)); bar.lineWidth = 26; bar.stroke()
        NSColor(calibratedRed:0.87,green:0.88,blue:0.82,alpha:1).setFill()
        let play = NSBezierPath(); play.move(to:NSPoint(x:446,y:390)); play.line(to:NSPoint(x:446,y:564)); play.line(to:NSPoint(x:590,y:477)); play.close(); play.fill()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let filename = "icon_\(size)x\(size)\(suffix).png"
        try rep.representation(using:.png,properties:[:])!.write(to:destination.appendingPathComponent(filename))
    }
}

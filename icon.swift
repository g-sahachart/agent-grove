// วาดไอคอน 1024x1024: พื้นเขียวมุมมน + 🐾  ใช้: swift icon.swift out.png
import Cocoa

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
NSColor(calibratedRed: 0.55, green: 0.81, blue: 0.45, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185).fill()
let text = NSAttributedString(string: "🐾", attributes: [.font: NSFont.systemFont(ofSize: 520)])
let t = text.size()
text.draw(at: NSPoint(x: (size - t.width) / 2, y: (size - t.height) / 2))
img.unlockFocus()

let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

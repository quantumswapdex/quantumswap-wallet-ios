// StatusIcons.swift
// Desktop checkmark-circle-outline / alert-outline ionicons rendered in
// code (Android ic_status_success.xml / ic_status_failed.xml), shown by
// the send-completed dialog once the transaction confirms / fails.

import UIKit

public enum StatusIcons {

    /// Outlined circle + check, theme green #34D399.
    public static func success(size: CGFloat = 30) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { ctx in
            let c = ctx.cgContext
            let s = size / 512
            c.scaleBy(x: s, y: s)
            c.setStrokeColor(UIColor(rgbHex: 0x34D399).cgColor)
            c.setLineWidth(32)
            c.setLineCap(.round)
            c.setLineJoin(.round)
            c.addEllipse(in: CGRect(x: 48, y: 48, width: 416, height: 416))
            c.strokePath()
            c.move(to: CGPoint(x: 352, y: 176))
            c.addLine(to: CGPoint(x: 217.6, y: 336))
            c.addLine(to: CGPoint(x: 160, y: 272))
            c.strokePath()
        }.withRenderingMode(.alwaysOriginal)
    }

    /// Android `alert_outline.xml` (ion alert): pure-red #FF0000
    /// exclamation - rounded bar + dot - used by the transactions
    /// table's failed marker. The stroked r16 dot at 32 stroke in the
    /// Android vector renders as a solid 32pt-radius disc, so it is
    /// drawn as a filled circle here.
    public static func alertOutline(size: CGFloat = 22) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { ctx in
            let c = ctx.cgContext
            let s = size / 512
            c.scaleBy(x: s, y: s)
            let red = UIColor(rgbHex: 0xFF0000)
            c.setStrokeColor(red.cgColor)
            c.setFillColor(red.cgColor)
            c.setLineWidth(32)
            c.setLineCap(.round)
            c.move(to: CGPoint(x: 256, y: 96))
            c.addLine(to: CGPoint(x: 256, y: 312))
            c.strokePath()
            c.fillEllipse(in: CGRect(x: 224, y: 368, width: 64, height: 64))
        }.withRenderingMode(.alwaysOriginal)
    }

    /// Exclamation bar + dot, failure red #FF5A64.
    public static func failed(size: CGFloat = 30) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { ctx in
            let c = ctx.cgContext
            let s = size / 512
            c.scaleBy(x: s, y: s)
            let red = UIColor(rgbHex: 0xFF5A64)
            c.setStrokeColor(red.cgColor)
            c.setFillColor(red.cgColor)
            c.setLineWidth(40)
            c.setLineCap(.round)
            c.move(to: CGPoint(x: 256, y: 96))
            c.addLine(to: CGPoint(x: 256, y: 320))
            c.strokePath()
            c.fillEllipse(in: CGRect(x: 228, y: 356, width: 56, height: 56))
        }.withRenderingMode(.alwaysOriginal)
    }
}

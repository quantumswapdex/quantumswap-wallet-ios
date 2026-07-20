// Typography.swift
// QuantumSwap ships Poppins (same family as the desktop wallet and
// the Android `relay_poppins_*` resources). Falls back to the system
// font when a face is missing from the app bundle.

import UIKit

public enum Typography {

    public static func body(_ size: CGFloat) -> UIFont {
        font(name: "Poppins-Regular", size: size, weight: .regular)
    }

    public static func mediumLabel(_ size: CGFloat) -> UIFont {
        font(name: "Poppins-Medium", size: size, weight: .medium)
    }

    public static func boldTitle(_ size: CGFloat) -> UIFont {
        font(name: "Poppins-Bold", size: size, weight: .bold)
    }

    public static func semiBold(_ size: CGFloat) -> UIFont {
        font(name: "Poppins-SemiBold", size: size, weight: .semibold)
    }

    public static func light(_ size: CGFloat) -> UIFont {
        font(name: "Poppins-Light", size: size, weight: .light)
    }

    public static func mono(_ size: CGFloat) -> UIFont {
        UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private static func font(name: String, size: CGFloat, weight: UIFont.Weight) -> UIFont {
        UIFont(name: name, size: size) ?? UIFont.systemFont(ofSize: size, weight: weight)
    }
}

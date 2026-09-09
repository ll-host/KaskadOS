function detailHeightForSection(section, maxHeight) {
    if (!section)
        return 0;
    if (section === "wifi")
        return Math.min(430, maxHeight);
    if (section === "bluetooth" || section === "builtin_vpn" || section === "builtin_tailscale")
        return Math.min(350, maxHeight);
    if (section.startsWith("brightnessSlider_"))
        return Math.min(400, maxHeight);
    return Math.min(250, maxHeight);
}

set(MACQUEEN_PORTAL_DATA_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../session")
set(MACQUEEN_PORTAL_EXECUTABLE "${CMAKE_INSTALL_FULL_LIBEXECDIR}/xdg-desktop-portal-macqueen")

configure_file(
    "${MACQUEEN_PORTAL_DATA_DIR}/org.freedesktop.impl.portal.desktop.macqueen.desktop.in"
    org.freedesktop.impl.portal.desktop.macqueen.desktop
    @ONLY)
configure_file(
    "${MACQUEEN_PORTAL_DATA_DIR}/org.freedesktop.impl.portal.desktop.macqueen.service.in"
    org.freedesktop.impl.portal.desktop.macqueen.service
    @ONLY)
configure_file(
    "${MACQUEEN_PORTAL_DATA_DIR}/xdg-desktop-portal-macqueen.service.in"
    xdg-desktop-portal-macqueen.service
    @ONLY)

install(FILES "${MACQUEEN_PORTAL_DATA_DIR}/macqueen.portal"
    DESTINATION ${KDE_INSTALL_DATADIR}/xdg-desktop-portal/portals)
install(FILES ${CMAKE_CURRENT_BINARY_DIR}/org.freedesktop.impl.portal.desktop.macqueen.service
    DESTINATION ${KDE_INSTALL_DBUSSERVICEDIR})
install(FILES ${CMAKE_CURRENT_BINARY_DIR}/org.freedesktop.impl.portal.desktop.macqueen.desktop
    DESTINATION ${KDE_INSTALL_APPDIR})
install(FILES ${CMAKE_CURRENT_BINARY_DIR}/xdg-desktop-portal-macqueen.service
    DESTINATION ${KDE_INSTALL_SYSTEMDUSERUNITDIR})

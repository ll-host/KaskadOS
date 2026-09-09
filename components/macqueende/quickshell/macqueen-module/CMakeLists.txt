cmake_minimum_required(VERSION 3.21)

project(QuickshellMacqueen VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_AUTOMOC ON)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Qt6 6.9 REQUIRED COMPONENTS Core DBus Qml)

qt_standard_project_setup(REQUIRES 6.9)

qt_add_qml_module(quickshell-macqueen
    URI Macqueen.Ipc
    VERSION 1.0
    RESOURCE_PREFIX /
    OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/Macqueen/Ipc
    SOURCES
        macqueenipcclient.cpp
        macqueenipcclient.h
)

target_link_libraries(quickshell-macqueen
    PRIVATE
        Qt6::Core
        Qt6::DBus
        Qt6::Qml
)

set_target_properties(quickshell-macqueenplugin PROPERTIES
    INSTALL_RPATH "$ORIGIN"
)

install(
    TARGETS quickshell-macqueen quickshell-macqueenplugin
    LIBRARY DESTINATION lib/qt6/qml/Macqueen/Ipc
    RUNTIME DESTINATION lib/qt6/qml/Macqueen/Ipc
)
install(
    FILES
        ${CMAKE_BINARY_DIR}/Macqueen/Ipc/qmldir
        ${CMAKE_BINARY_DIR}/Macqueen/Ipc/quickshell-macqueen.qmltypes
    DESTINATION lib/qt6/qml/Macqueen/Ipc
)

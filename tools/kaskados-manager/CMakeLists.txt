cmake_minimum_required(VERSION 3.24)
project(kaskados-manager VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

find_package(Qt6 6.6 REQUIRED COMPONENTS Widgets)

qt_standard_project_setup()
qt_add_executable(kaskados-manager
  main.cpp
)

target_link_libraries(kaskados-manager PRIVATE Qt6::Widgets)
target_compile_options(kaskados-manager PRIVATE -Wall -Wextra -Wpedantic)

install(TARGETS kaskados-manager RUNTIME DESTINATION bin)

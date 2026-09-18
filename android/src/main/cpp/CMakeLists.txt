cmake_minimum_required(VERSION 3.22.1)
project(traceroute LANGUAGES C)

add_library(traceroute SHARED traceroute.c)

target_link_libraries(traceroute log)

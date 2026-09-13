#include "message.hpp"
#include <cstdio>

int main() {
    std::printf("Mixed languages: %d\n", message_value());
    return message_value() == 42 ? 0 : 1;
}

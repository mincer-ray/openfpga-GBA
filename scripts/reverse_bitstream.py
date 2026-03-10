#!/usr/bin/env python3
"""Reverse bits in each byte of an RBF file for Analogue Pocket."""
import sys


def reverse_byte(b):
    return int(f'{b:08b}'[::-1], 2)


def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} input.rbf output.rbf_r")
        sys.exit(1)

    with open(sys.argv[1], 'rb') as f:
        data = f.read()

    reversed_data = bytes(reverse_byte(b) for b in data)

    with open(sys.argv[2], 'wb') as f:
        f.write(reversed_data)

    print(f"Reversed {len(data)} bytes: {sys.argv[1]} -> {sys.argv[2]}")


if __name__ == '__main__':
    main()

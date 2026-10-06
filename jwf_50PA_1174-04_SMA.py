#!/usr/bin/python3
# -*- coding: utf-8 -*-
"""JFW 50PA-1174-04 SMA Attenuator control utility.

Sends SAA/SA/RAA commands to the attenuator over a TCP socket.
Connection settings are hardcoded below (no .cfg / .ini files).
"""

import argparse
import re
import socket
import sys

HOST = "192.168.1.250"
PORT = 3001
PROMPT = "JFW>>"

RECV_BUFSIZE = 4096
RECV_TIMEOUT_SEC = 2


def parse_args():
    parser = argparse.ArgumentParser(description="JFW 50PA-1174-04 SMA Attenuator Control")
    parser.add_argument("-a1", "--att1", dest="att1", type=int, help="Set atten1 to Attenuator")
    parser.add_argument("-a2", "--att2", dest="att2", type=int, help="Set atten2 to Attenuator")
    parser.add_argument("-a3", "--att3", dest="att3", type=int, help="Set atten3 to Attenuator")
    parser.add_argument("-a4", "--att4", dest="att4", type=int, help="Set atten4 to Attenuator")
    parser.add_argument("-e", "--each", dest="each", type=int, nargs=4,
                         help="Set EACH value to Attenuator")
    parser.add_argument("-a", "--all", dest="all", type=int, help="Set SAME value to Attenuator")
    parser.add_argument("-r", "--read", dest="read", default=False, action="store_true",
                         help="Read values from Attenuator")
    args = parser.parse_args()

    if args.read:
        atten_values = [None] * 4
    elif args.all is not None:
        atten_values = [args.all] * 4
    elif args.each is not None:
        atten_values = args.each
    else:
        atten_values = [args.att1, args.att2, args.att3, args.att4]

    return args.read, atten_values


def build_command(read_flag, atten_values):
    """Build the SA/SAA + RAA command string to send to the attenuator."""
    command = ""
    unique_values = set(atten_values)
    if len(unique_values) > 1:
        for i, value in enumerate(atten_values):
            if value is not None:
                command += "SA %d %d\r\n" % (i + 1, value)
    else:
        value = next(iter(unique_values))
        if value is not None:
            command += "SAA %s\r\n" % value

    command += "RAA\r\n"
    return command


def parse_response(response):
    """Extract the 4 attenuator dB readings from the device response."""
    matches = re.findall(r"Atten #(\d+) = (\d+)dB", response.strip())
    return list(dict(matches).values())


def recv_until(sock, prompt, bufsize=RECV_BUFSIZE):
    """Read from the socket until the accumulated data ends with the prompt."""
    received = ""
    while not received.strip().endswith(prompt):
        data = sock.recv(bufsize)
        if not data:
            break
        received += data.decode("utf-8")
    return received


def run(read_flag, atten_values):
    command = build_command(read_flag, atten_values)

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.settimeout(RECV_TIMEOUT_SEC)
        sock.connect((HOST, PORT))
        recv_until(sock, PROMPT)

        response = ""
        try:
            sock.send(command.encode("utf-8"))
            response = recv_until(sock, PROMPT)
        except OSError as err:
            print(err)

    atten_values_out = parse_response(response)
    print("Atten #[1-4] :", " ".join(atten_values_out))
    return atten_values_out


def main():
    return run(*parse_args())


if __name__ == "__main__":
    if sys.version_info < (3, 7):
        pyver = ".".join(str(v) for v in sys.version_info[:3])
        print(" warning ".center(50, "!"))
        print("Python version is needed over 3.6 for running program")
        print("It is created the program on ver 3.8.2 of python")
        print("Python version of yours is ver {}".format(pyver))
        sys.exit(-1)

    try:
        main()
    except KeyboardInterrupt as e:
        print("\nWARNING....   WARNING....")
        print(e)
        print("The program is stopped forced\n")

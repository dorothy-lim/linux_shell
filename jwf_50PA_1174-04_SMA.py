#!/usr/bin/python3
# -*- coding: utf-8 -*-
"""JFW 50PA-1174-04 SMA Attenuator control utility.

Reads connection settings from ini/atten_env.ini + ini/atten_config.cfg
(auto-created with defaults on first run) and sends SAA/SA/RAA commands
to the attenuator over a TCP socket.
"""

import argparse
import configparser
import os
import re
import socket
import sys

CFG_DEFAULT = """
[CFG_DEFAULT]
[COMMON]
[PATH]
[SOCKET]
host = 192.168.100.250
port = 3001
prompt = JFW>>
"""

ENV_DEFAULT = """
[ENV_DEFAULT]
cfg = atten_config.cfg
[COMMON]
[PATH]
gui_path = ui
icon_path = icon
"""

SUB_DIR = "ini"
CONFIG_FILE = "atten_config.cfg"
ENV_INI_FILE = "atten_env.ini"

RECV_BUFSIZE = 4096
RECV_TIMEOUT_SEC = 2


class CConfigParser:
    """Thin wrapper around configparser that auto-creates missing ini files."""

    def __init__(self):
        self._cache = {}
        self.ini_parser = self._load(ENV_INI_FILE, ENV_DEFAULT)
        # Use the config filename declared in the env ini, falling back to the default.
        self.config_file = self.ini_parser.get("ENV_DEFAULT", "cfg", fallback=CONFIG_FILE)
        self.cfg_parser = self._load(self.config_file, CFG_DEFAULT)

    @staticmethod
    def _path(fname, sub_dir=SUB_DIR):
        return os.path.join(os.getcwd(), sub_dir, fname)

    def _load(self, fname, default_text, sub_dir=SUB_DIR):
        path = self._path(fname, sub_dir)
        parser = configparser.ConfigParser(
            interpolation=configparser.ExtendedInterpolation(), allow_no_value=True
        )
        if os.path.isfile(path):
            parser.read(path)
        else:
            parser.read_string(default_text)
            self._save(parser, fname, sub_dir)
        self._cache[fname] = parser
        return parser

    @staticmethod
    def _save(parser, fname, sub_dir=SUB_DIR):
        path = CConfigParser._path(fname, sub_dir)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as configfile:
            parser.write(configfile)

    def get_param(self, fname, section, sub_dir=SUB_DIR):
        parser = self._cache.get(fname) or self._load(fname, CFG_DEFAULT, sub_dir)
        try:
            return dict(parser.items(section))
        except configparser.NoSectionError as err:
            print(err, "in {}".format(self._path(fname, sub_dir)))
            return {}

    def set_param(self, fname, section, option, value, sub_dir=SUB_DIR, append=True):
        parser = self._cache.get(fname) or self._load(fname, CFG_DEFAULT, sub_dir)
        if not parser.has_section(section):
            parser.add_section(section)
        if not append:
            for opt in parser.options(section):
                parser.remove_option(section, opt)
        parser.set(section, option, str(value))
        self._save(parser, fname, sub_dir)
        return parser


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
    cfg_parser = CConfigParser()
    socket_params = cfg_parser.get_param(cfg_parser.config_file, "SOCKET")

    host = socket_params["host"]
    port = int(socket_params["port"])
    prompt = socket_params["prompt"]

    command = build_command(read_flag, atten_values)

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.settimeout(RECV_TIMEOUT_SEC)
        sock.connect((host, port))
        recv_until(sock, prompt)

        response = ""
        try:
            sock.send(command.encode("utf-8"))
            response = recv_until(sock, prompt)
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

    cur_path = os.getcwd()
    work_path = os.path.realpath(__file__)
    try:
        os.chdir(os.path.dirname(work_path))
        print("Working Dir:", os.getcwd())
        main()
    except KeyboardInterrupt as e:
        print("\nWARNING....   WARNING....")
        print(e)
        print("The program is stopped forced\n")
    finally:
        os.chdir(cur_path)

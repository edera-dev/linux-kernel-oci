# coding: utf-8
# Copyright Ruamel bvba 2007-2014

from __future__ import print_function

import argparse


class SplitAppendAction(argparse._AppendAction):
    """append to list, like normal "append", but split first
    (default split on ',')

    parser = argparse.ArgumentParser()
    parser.add_argument('-d', action=SplitAppendAction)

    the following argument have the same list as result:
       -d ab -d cd -d kl -d mn
       -d ab,cd,kl,mn
       -d ab,cd -d kl,mn
    """
    def __init__(self, *args, **kw):
        self._split_chr = ','
        argparse.Action.__init__(self, *args, **kw)

    def __call__(self, parser, namespace, values, option_string=None):
        # _AppendAction does not return a value
        for value in values.split(self._split_chr):
            argparse._AppendAction.__call__(
                self, parser, namespace, value, option_string)

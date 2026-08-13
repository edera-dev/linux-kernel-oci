# coding: utf-8
# Copyright Ruamel bvba 2007-2014

from __future__ import print_function

import argparse


class CheckSingleStoreAction(argparse.Action):
    """issue a warning when the store action is called multiple times"""

    def __call__(self, parser, namespace, values, option_string=None):
        if getattr(namespace, self.dest, None) is not None:
            print(
                'WARNING: previous optional argument "'
                + option_string
                + ' '
                + str(getattr(namespace, self.dest))
                + '" overwritten by "'
                + str(option_string)
                + ' '
                + str(values)
                + '"'
            )
        setattr(namespace, self.dest, values)

# coding: utf-8
# Copyright Ruamel bvba 2007-2018

from __future__ import print_function, absolute_import, division, unicode_literals

import argparse
import datetime


class DateAction(argparse.Action):
    """argparse action for parsing dates with or without dashes

    parser = argparse.ArgumentParser()
    parser.add_argument('--verbose', '-v', action=DateAction)
    """
    def __init__(self, option_strings, dest, nargs=None, **kwargs):
        if nargs != 1 and nargs not in [None, '?', '*']:
            raise ValueError("DateAction can only have one argument")
        super(DateAction, self).__init__(option_strings, dest, nargs=nargs, **kwargs)

    def __call__(self, parser, namespace, values, option_string=None):
        if values is None:
            return None
        s = values
        for c in './-_':
            s = s.replace(c, '')
        val = datetime.datetime.strptime(s, '%Y%m%d').date()
        #    val = self.const
        setattr(namespace, self.dest, val)

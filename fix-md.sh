#!/bin/bash
> README.md
pod2markdown < lib/Data/Tools/Process.pm          >> README.md
pod2markdown < lib/Data/Tools/Process/Forks.pm    >> README.md
pod2markdown < lib/Data/Tools/Process/ForkPool.pm >> README.md

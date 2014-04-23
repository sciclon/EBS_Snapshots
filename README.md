EBS_Snapshots
=================

EBS Automatic SnapShots
Overview

I came across with many people looking for a tool to administrate the EBS snapshots.
I found several tools in internet but they were just scripts and incomplete solutions.
Finally I decided to create a program more flexible, centralized and easy to administrate.

The main idea is to have a centralized program to rule all the EBS volumes and snapshots.
Besides you can  hook your code before running each snapshot and after it. 

Some features on their way

* Synchronous  waiting state in create/delete snapshot getting a real complete/fail status.
* Timeout to Synchronous  waiting state.
* Timeout to prescript/postscript execution.
* Pass some environment variable to prescript and postscript.

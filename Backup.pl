#!/usr/bin/perl

#####################################################
## Backup v1.0
## 2014-04-21
## (r)  2014
## Author: Sergio Troiano (sergio_troiano@hotmail.com)
######################################################


use sigtrap 'handler' => \&clean_exit, 'INT', 'ABRT', 'QUIT', 'TERM';
use Config::Tiny;
use Getopt::Std;
use VM::EC2;
use VM::EC2::Instance::Metadata;
use Date::Parse;
## MAIN

## Lock
_lock('lock');


## Get configs from config file
my $main_cfg = get_cfg_file_info();

## Daemon mode
if($main_cfg->{'daemon_mode'} eq 'y')
{
    while(1)
    {

        ## Creating EC2 object
        my $ec2 = ec2_create($main_cfg);

        ## Getting info about the volumes via AWS API
        my $volumes = volumes_api_info($main_cfg, $ec2);

        ## Getting info about snapshots via AWS API
        my $snapshots = snapshots_api_info($volumes, $ec2);

        ## Use all the info to check if we need to create/remove any some snapshot
        do_snapshots($snapshots, $ec2);

	## Daemon mode loop, waiting for some event (Cache expires or force reload config)
	while(1)
	{
	    ## Let's check the local cache to avoid extra API calls
	    last if(local_cache($snapshots));
	
	    ## Force reconfigure
	    if(reconfigure())
	    {
		$main_cfg = get_cfg_file_info();
		last;
	    }
            sleep(20);
	}

    }
}
## Scripting mode
else
{

        ## Creating EC2 object
        my $ec2 = ec2_create($main_cfg);

        ## Getting info about the volumes via AWS API
        my $volumes = volumes_api_info($main_cfg, $ec2);

        ## Getting info about snapshots via AWS API
        my $snapshots = snapshots_api_info($volumes, $ec2);

        ## Use all the info to check if we need to create/remove any some snapshot
        do_snapshots($snapshots, $ec2);

	## Unlock
	_lock('unlock');

}


######################## FUNCTIONS #######################################
## Getiing information from the config file
sub get_cfg_file_info
{
    ## Is there any config file defined?
    getopts("c:", \%cmd_opts);
    (clean_exit(), die  "You have to define a config file ie: -c /etc/myconfig.cnf\n") if (!defined($cmd_opts{c}));
    (clean_exit(), die "$cmd_opts{c} No such file or directory\n") if (!-f $cmd_opts{c});

    # Create a config
    my $config = Config::Tiny->new;

    # Open the config
    $config = Config::Tiny->read($cmd_opts{c});

    ## Getting config values
    my %general_config;
    my @volumes;
    ## Splitting volumes of general config
    foreach my $tag (keys %{$config})
    {
	if ($tag eq 'general'){ %general_config = %{$config->{$tag}};next;}
	if($tag =~ /^vol\-\w+$/)
	{
	    $config->{$tag}->{'volumeId'} = $tag;
	    push @volumes, $config->{$tag};
	    next;
	}
        _log('STDOUT', 'warn', "[$tag] is not a valid tag, skipping");

    }
    ## Getting Metadata, instanceId and region
    my $meta = VM::EC2::Instance::Metadata->new;
    (_log('STDOUT', 'fatal',"Error getting instance metadata"), clean_exit(), die "Error getting instance metdadata") if (!defined($meta)); 
    my $instance_id = $meta->instanceId;
    (_log('STDOUT', 'fatal',"Error getting instance id, Who am I?"), clean_exit(), die "Error getting instance id, Who am I?") if ($instance_id !~ /^i\-\w+$/); 
    $general_config{'me'} = $instance_id;
    $general_config{'region'} = $meta->region;
    

    ## Validating general input data from config file
    if(!defined($general_config{'logfile'}) || ($general_config{'logfile'} eq '') ){_log('STDOUT', 'warn', 'You should define log file in [general]->logfile, default log STDOUT'), $general_config{'logfile'} = 'STDOUT';}
    ## Valid path!!!
    if(!defined($general_config{'daemon_mode'})){_log($general_config{'logfile'}, 'warn', 'You should define daemon_mode in [general]->daemon_mode, running in script mode'), $general_config{'daemon_mode'} = n;}
    (_log($general_config{'logfile'}, 'warn', "[general]->daemon_mode value should be (y/n) char value!, running in script mode") ,$general_config{'daemon_mode'} = n) if ($general_config{'daemon_mode'} !~ m/^(y|n){1}$/);
    if(!defined($general_config{'AWSAccessKeyId'})){_log($general_config{'logfile'}, 'fatal', 'You must define AWSAccessKeyId in [general]->AWSAccessKeyId, stopping'), exit(0);}
    if(!defined($general_config{'SecretAccessKey'})){_log($general_config{'logfile'}, 'fatal', 'You must define SecretAccessKey in [general]->SecretAccessKey, stopping'), exit(0);}
    if(!defined($general_config{'only_attached_volumes'})){_log($general_config{'logfile'}, 'warn', 'You should define only_attached_volumes in [general]->only_attached_volumes, default y');}


    ## Validating volumes input data
    if(!@volumes){_log($general_config{'logfile'}, 'fatal', 'You must define at least one volume, for example  [vol-XXXXXXX] , stopping'), exit(0);}

    ## Validating each value in block devices, ommiting block devices with a wrong value
    foreach my $volume(@volumes)
    {
        if(!defined($volume->{'freq'})){_log($general_config{'logfile'}, 'warn', "You must define freq in [$volume->{'volumeId'}]->freq, skipping"), $volume->{'to_snap'} = 'false', next;}
	## Freq Hs to seconds
	$volume->{'freq'} = $volume->{'freq'}* 3600;
        if(!defined($volume->{'quantity'})){_log($general_config{'logfile'}, 'warn', "You must define quantity in [$volume->{'volumeId'}]->quantity, skipping"), $volume->{'to_snap'} = 'false', next;}
	## Valid pre and postcript
	$volume->{'to_snap'} = 'true'; 


	## Optionals configs
        if(defined($volume->{'protected_snapshots'}))
	{
	    my %protected_snapshots_tmp;
	    ## remove white spaces
	    my @tmp = split(',', $volume->{'protected_snapshots'});
	    foreach(@tmp)	    
	    {
		## Remove white spaces
		$_ =~ s/^\s*(.*?)\s*$/$1/;
		(_log($general_config{'logfile'}, 'warn', "Bad protected snapshot format in [$volume->{'volumeId'}]->protected_snapshots, skipping volume\n"), $volume->{'to_snap'} = 'false', last) if ($_ !~ m/^snap\-\w+$/);
	        $protected_snapshots_tmp{$_} = 1; 
	    }
	    $volume->{'protected_snapshots'} = \%protected_snapshots_tmp;
	}
        if(!defined($volume->{'skip_if_prescript_fails'}) && defined($volume->{'prescript'}) ){_log($general_config{'logfile'}, 'warn', "You should define skip_if_prescript_fails in [$volume->{'volumeId'}]->skip_if_prescript_fails, default n"), $volume->{'skip_if_prescript_fails'} = 'n' ;}
        (_log($general_config{'logfile'}, 'warn', "[$volume->{'volumeId'}]->skip_if_prescript_fails value should be (y/n) char value!, default n"), $volume->{'skip_if_prescript_fails'} = 'n')  if (defined($volume->{'skip_if_prescript_fails'}) && ($volume->{'skip_if_prescript_fails'} !~ m/^(y|n){1}$/));

        if( defined($volume->{'prescript'}) && (!-x $volume->{'prescript'}))
	{
	    _log($general_config{'logfile'}, 'warn', "[$volume->{'prescript'}]->prescript file does not exist or is not an executable file, skipped"),undef $volume->{'prescript'};
	}
        if( defined($volume->{'postscript'}) && (!-x $volume->{'postscript'}))
	{
	    _log($general_config{'logfile'}, 'warn', "[$volume->{'postscript'}]->postscript file does not exist or is not an executable file, skipped"),undef $volume->{'postscript'};
	}

    }

    ## Returning general config + volumes config
    $general_config{'volumes'} = \@volumes;
    return \%general_config;
}
###################################

## Creating EC2 object
sub ec2_create
{
    my $ref_cfg_info = shift;

    ### Region and error control
    ## get new EC2 object
    my $ec2 = VM::EC2->new
    (
	-access_key => $ref_cfg_info->{'AWSAccessKeyId'},
        -secret_key => $ref_cfg_info->{'SecretAccessKey'},
        -endpoint   => 'http://ec2.amazonaws.com',
        -region => $ref_cfg_info->{'region'}
    );

    (_log($ref_cfg_info{'logfile'}, 'fatal', "Error getting from the AWS API error: $ec2->{error}->{data}->{Code}\n"), exit(0)) if (defined($ec2->{error}->{data}->{Code}));

    ## Returning EC2 object
    return \$ec2;
}
###################################

## Getting information from AWS API about volumes
sub volumes_api_info
{
    my $ref_cfg_info = shift;
    my $ec2 = shift;

    ## Getting info about volumes
    foreach(@{$ref_cfg_info->{'volumes'}})
    {
        my @res = $$ec2->describe_volumes(-volume_id => $_->{'volumeId'});
        (_log($ref_cfg_info->{'logfile'},'warn',"Error getting information of volume $_->{'volumeId'} from AWS API, skipping"), $_->{'to_snap'} = 'false', next) if (!@res); 
        (_log($ref_cfg_info{'logfile'}, 'warn', "Error getting volume info $_->{'volumeId'} from the AWS API error: $$ec2->{'aws'}->{'error'}\n"), next) if (defined($$ec2->{'aws'}->{'error'}));

	$_->{'status'} = $res[0]->{'data'}->{'attachmentSet'}->{'item'}[0]->{'status'};
	$_->{'instanceId'} = $res[0]->{'data'}->{'attachmentSet'}->{'item'}[0]->{'instanceId'};
    }
    ## Lets save the local TimeStamp of the API to avoid extra API calls (cache)
    $ref_cfg_info->{'last_api_call'} = time();
    my %result = %{$ref_cfg_info};
    return \%result;

}
######################################

## Getting SnapShots info
sub snapshots_api_info
{
    my $ref_cfg_info = shift;
    my $ec2 = shift;

    ## Getting snapshots for each block device
    foreach(@{$ref_cfg_info->{volumes}})
    {
	## Skip wrong volumes
	next if ($_->{'to_snap'} eq 'false');

	my %filters;
	$filters{'volume-id'} = $_->{'volumeId'};
	my @snaps = $$ec2->describe_snapshots(-filter =>\%filters);

        (_log($ref_cfg_info{'logfile'}, 'warn', "Error getting snapshot info $_->{'volumeId'} from the AWS API error: $$ec2->{'aws'}->{'error'}\n"), next) if (defined($$ec2->{'aws'}->{'error'}));

	my @tmp_snaps;
	SNAP: foreach my $snapshot (@snaps)
	{
	    ## Skip protected snapshots
	    my %protected_snapshots = %{$_->{'protected_snapshots'}};
	    (_log($ref_cfg_info->{'logfile'},'info', "Protected snapshot $snapshot->{'data'}->{'snapshotId'} in volume $_->{'volumeId'}, skipping"), next SNAP) if ($protected_snapshots{$snapshot->{'data'}->{'snapshotId'}});

	    ## Is there is a tag the snapshot is in use, skip it
	    (_log($ref_cfg_info->{'logfile'},'warn', "It looks like snapshot $snapshot->{'data'}->{'snapshotId'} in volume $snapshot->{'data'}->{'volumeId'} is in use, skipping!"), next) if(defined($snapshot->{'data'}->{'tagSet'}));
	    my %tmp;
	    $tmp{'startTime'} = $snapshot->{'data'}->{'startTime'};
	    $tmp{'status'} = $snapshot->{'data'}->{'status'};
	    $tmp{'snapshotId'} = $snapshot->{'data'}->{'snapshotId'};
	    push @tmp_snaps, \%tmp;
	}
	$_->{'snapshots'} = \@tmp_snaps;
    }
    my %res = %{$ref_cfg_info};

    return \%res;

}
###################################

## Lock file to avoid several processes running
sub _lock
{
    my $action = shift;

    if ((-e '/tmp/bck.lock') && ($action eq 'unlock'))
    {
	unlink '/tmp/bck.lock';
	return;
    }
    if ($action eq 'lock')
    {
	(die "It looks like the process is already running  (check lock file in /tmp/bck.lock)\n") if (-e '/tmp/bck.lock');
	open(LOCK,">/tmp/bck.lock");close(LOCK);
    }

}
###################################

## Creating/Removing Snapshots
sub do_snapshots
{
    my $ref_cfg_info = shift;
    my $ec2 = shift;

    ## lets start te checks
    foreach(@{$ref_cfg_info->{'volumes'}})
    {
	## Skipping no valid volumes
	next if ($_->{'to_snap'} eq 'false');

	## Are remote volumes allowed?
	if( ($ref_cfg_info->{'only_attached_volumes'} eq 'y') && ($ref_cfg_info->{'me'} ne $_->{'instanceId'}))
	{
	    _log($ref_cfg_info->{'logfile'}, 'warn', "volumes not attached in this instance are not allowed!, you can modify this in \[general\]->only_attached_volumes, volume $_->{'volumeId'} skipped");
	    next;
	}	

	my %snaps_ts_key;
	my $first_snap  = 999999999999; my $last_snap = 0;
        my $total_snapshots = 0;
	foreach my $snap (@{$_->{'snapshots'}})
	{

	    $snaps_ts_key{ str2time($snap->{'startTime'})} = $snap->{'snapshotId'};
	    $first_snap =  str2time($snap->{'startTime'}) if ( str2time($snap->{'startTime'}) < $first_snap);
	    $last_snap =  str2time($snap->{'startTime'}) if ( str2time($snap->{'startTime'}) > $last_snap);

	}

        ## Getting current timestamp from the API, we avoid any misscofigured server clock
        my $now = str2time($$ec2->timestamp);
        (_log($ref_cfg_info->{'logfile'}, 'fatal',"Error getting current timestamp from the API to volume $_->{'volumeId'}, skipping"), next) if (!defined($now) || ($now !~/^\d+$/)); 

        ## If the quantity is lower than limit and freq is longer than the last snap we create a new snpashot
        if (scalar(keys(%snaps_ts_key)) < $_->{'quantity'} && (($now - $last_snap) >= $_->{'freq'}))
	{
	    ## Prescript execution
	    if(defined($_->{'prescript'}))
	    {
    	        if(_prescript($_->{'prescript'}) != 0)
	        {
	            if( $_->{'skip_if_prescript_fails'} eq 'y')
		    {
	                _log($ref_cfg_info->{'logfile'}, 'warn',"Prescript execution failed! skipping snapshot creation in $_->{'volumeId'}");
		        next;
		    }
		    _log($ref_cfg_info->{'logfile'}, 'info',"Prescript execution failed! in $_->{'volumeId'}");
	        }
	        else{_log($ref_cfg_info->{'logfile'}, 'info',"Prescript execution success in $_->{'volumeId'}");}
	    }
	    $snapshot = $$ec2->create_snapshot(-volume_id=>$_->{'volumeId'},-description=>"Created automatically by instance $_->{'instanceId'}");
            (_log($ref_cfg_info->{'logfile'}, 'warn', "Error creating snapshot API: $$ec2->{'aws'}->{'error'}\n"), next) if (defined($$ec2->{'aws'}->{'error'}));
	    (_log($ref_cfg_info->{'logfile'}, 'warn',"The snapshot of the volume  $_->{'volumeId'} was taken but the Postscript execution failed!"), next) if (_postscript($_->{'postscript'}) != 0);
	    _log($ref_cfg_info->{'logfile'}, 'info',"The snapshot of the volume $_->{'volumeId'} was taken");
	    next;
	}
	## If the quantity of snashots is bigger than the limit lets reduce it until reaching the limit
	if (scalar(keys(%snaps_ts_key)) > $_->{'quantity'})
	{
	    my $to_delete = scalar(keys(%snaps_ts_key)) - $_->{'quantity'};
	    my $count = 0;
	    for $ctime ( sort {$a<=>$b} keys %snaps_ts_key) 
	    {
 	        (_log($ref_cfg_info->{'logfile'}, 'warn', "It was an error trying to delete the snapshot  $_->{'snapshotId'} in volume $_->{'volumeId'}, skipping"), next) if(!$$ec2->delete_snapshot($snaps_ts_key{$ctime}));
 
        	_log($ref_cfg_info->{'logfile'}, 'info',"quantity of snapshots bigger than limit, deleting in $_->{'volumeId'} the snapshot $snaps_ts_key{$ctime}");
		$count++;
		last if ($count >= $to_delete);
	    }
	}
	## If the quantity is equal lets check if we have to replace the oldest snap for q new one
	if ( (scalar(keys(%snaps_ts_key)) == $_->{'quantity'}) && (scalar(keys(%snaps_ts_key)) >= 1))
	{
	    if(($now - $last_snap) >= $_->{'freq'})
	    {
	        ## Create first, check if it was created and delete the oldest

		## Prescript execution
		if(defined($_->{'prescript'}))
		{
    	            if(_prescript($_->{'prescript'}) != 0)
	            {
	                if( $_->{'skip_if_prescript_fails'} eq 'y')
		        {
	                    _log($ref_cfg_info->{'logfile'}, 'warn',"Prescript execution failed! skipping snapshot creation in $_->{'volumeId'}");
		            next;
		        }
		         _log($ref_cfg_info->{'logfile'}, 'info',"Prescript execution failed! in $_->{'volumeId'}");
	            }
	            else{_log($ref_cfg_info->{'logfile'}, 'info',"Prescript execution success in $_->{'volumeId'}");}
		}
	
		## Create
    	        my $snapshot = $$ec2->create_snapshot(-volume_id=>$_->{'volumeId'},-description=>"Created automatically by instance $_->{'instanceId'}");
                (_log($ref_cfg_info->{'logfile'}, 'warn', "Error creating snapshot API: $$ec2->{'aws'}->{'error'}\n"), next) if (defined($$ec2->{'aws'}->{'error'}));
	        _log($ref_cfg_info->{'logfile'}, 'info',"creating a new snapshot in volume  $_->{'volumeId'}");

		## Delete
 	        (_log($ref_cfg_info->{'logfile'}, 'warn', "It was an error trying to delete the snapshot $snaps_ts_key{$first_snap} in volume $_->{'volumeId'}, skipping"), next) if(!$$ec2->delete_snapshot($snaps_ts_key{$first_snap}));
	        _log($ref_cfg_info->{'logfile'}, 'info',"deleting the oldest snapshot $snaps_ts_key{$first_snap} in volume  $_->{'volumeId'}");
   	        (_log($ref_cfg_info->{'logfile'}, 'warn',"The snapshot of the volume  $_->{'volumeId'} was taken but the Postscript execution failed!"), next) if (_postscript($_->{'postscript'}) != 0);
	    }	    
	}
    }
}
###########################################

##  Function to try to avoid API calls due to the frequency
sub local_cache
{

    my $snapshots = shift;
    my $now = time();
    my $last_api_call = $snapshots->{'last_api_call'};

    ## Returns 1 if any frquence volume is longer than the last API call
    foreach my $volumes (@{$snapshots->{'volumes'}})
    {
	my $freq = $volumes->{'freq'};
	if((!defined($now)) ||(!defined($freq)) ||(!defined($last_api_call)) )
	{
	    _log($snapshots->{'logfile'}, 'warn', "Some local cache variable is missing, skipping local cache mode (API calls each 20 seconds!");
	    return 1;
	}
	return 1 if (($now - $last_api_call) > $freq );
    }
    return 0;

}
###########################################

##  Force a reload config in Daemon mode
sub reconfigure
{

    if (-e "/tmp/\.reconfigure\.$$")
    {
	unlink "/tmp/\.reconfigure\.$$";
	return 1;
    }
    return 0;

}
##############################################

## Logging function
sub _log
{
    ## Type; fatal, warn, info
    my $fd = shift;
    my $type = shift;
    my $line = shift;
    my $date = localtime(time);
    if ($fd eq 'STDOUT'){print $date." ".$type." ".$line."\n"}
    else
    {
	if (!open(LOG, ">>$fd")){ print $date." "."Error opening log file, logs going to STDOUT\n"; print $type." ".$line."\n"; return;}
	print LOG $date." ".$type." ".$line."\n";
	close(LOG);
    }
}
##########################################

## Execute a script given before creating the snapshot, it will return the exit code of the  child
## The snapshot exectuion is related of the success of the script
sub _prescript
{
    my $prescript = shift;
    return system($prescript);
}
###########################################

## Execute a script given after creating the snapshot, it will return the exit code of the  child
sub _postscript
{
    my $postcript = shift;
    return system($postcript);
}

############################################

## Help command
sub _help
{



}
##############################################

sub clean_exit
{

    _log($main_cfg->{'logfile'}, 'info', "Caught a kill signal,  exiting");

    ## remove lock file
    unlink "/tmp/\.reconfigure\.$$";
    unlink "/tmp/bck.lock";
    exit(0);
}
###############################################

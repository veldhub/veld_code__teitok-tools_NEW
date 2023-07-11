use Getopt::Long;
use Data::Dumper;
use POSIX qw(strftime);
use File::Find;
use LWP::Simple;
use LWP::UserAgent;
use JSON;
use XML::LibXML;

# Convert a UDPIPE corpus into a TEITOK corpus (to have it convert back to Manatee)

$scriptname = $0;

GetOptions ( ## Command line options
            'debug' => \$debug, # debugging mode
            'verbose' => \$verbose, # verbose mode
            'test' => \$test, # test mode (print, do not save)
            'nobu' => \$nobu, # do not make a backup
            'emptys' => \$emptys, # do not make a backup
            'cid=s' => \$cid, # which UDPIPE model to use
            'input=s' => \$input, # which UDPIPE model to use
            'tmpfolder=s' => \$tmpfolder, # Folders where conllu files will be placed
            );

$\ = "\n"; $, = "\t";

@udflds = ( "ord", "word", "lemma", "upos", "xpos", "feats", "ohead", "deprel", "deps", "misc" ); 
%ord2id = ();
@nerlist = ();

@warnings = ();

if ( $debug ) { $verbose = 1; };
if ( $verbose ) { print "Loading $input into $cid"; };

if ( !-e $cid ) {
	print "No such XML file: $cid";
};
$parser = XML::LibXML->new(); $doc = "";
eval {
	$doc = $parser->load_xml(location => $cid );
};
if ( !$doc ) { print "Failed to load XML in $cid"; exit; };
for $tok ( $doc->findnodes("//tok[not(dtok)] | //dtok") ) {
	$id = $tok->getAttribute("id");
	$toklist{$id} = $tok;
};

if ( !-e $input ) {
	print "No such input file: $input";
};
conllu2tei($input);

# Place the NER if we have any
foreach $ner ( @nerlist ) {
	$sameas = $ner->getAttribute("sameAs");
	$ener = $doc->findnodes("//name[\@sameAs=\"$sameas\"]");
	if ( $ener ) {
		$ener->setAttribute('type', $ner->getAttribute('type'));
	} else {
		@tmp = split(' ', $sameas);
		$tok1 = substr($tmp[0], 1);
		$tok = $toklist{$tok1};
		$tok->parentNode->insertBefore($ner, $tok);
		if ( !$emptys ) {
			moveinside($ner);
		};
	};
};

if ( scalar @warnings ) {
	$warnlist = "'warnings': ['".join("', '", @warnings)."']";
};	

if ( $test ) { 
	print $doc->toString;
} else {

	# Make a backup of the file
	if ( !$nobu ) {
		( $buname = $cid ) =~ s/xmlfiles.*\//backups\//;
		$date = strftime "%Y%m%d", localtime; 
		$buname =~ s/\.xml/-$date.nt.xml/;
		$cmd = "/bin/cp '$filename' '$buname'";
		`$cmd`;
	};
	
	open FILE, ">$cid";
	print FILE $doc->toString;
	close FILE;

	print "{'success': 'CoNLL-U file successfully read back to $cid'$warnlist}";

};

sub conllu2tei($fn) {
	$fn = @_[0]; $tokcnt = 1; %tok = (); %mtok = (); %etok = (); %etok = (); %sent = (); $scnt=1; $mtokcnt=1; $prevdoc = "";
	if ( $fn =~ /\/([a-z]+)_([a-z]+)-ud-([a-z]+).conllu/ ) { $lang = $1; $name = $2; $part = $3; };
	$linex = ""; 

	$/ = "\n";
	open FILE, $fn; $insent = 0; $inpar = 0; $indoc = 0; $doccnt =1;
	while ( <FILE> ) {	
		$line = $_; chop($line);
		if ( $line =~ /# newdoc id = (.*)/ || $line =~ /# newdoc/ ) {
			$indoc = $1 or $indoc = "doc$doccnt";
			$doccnt++;
		} elsif ( $line =~ /# newpar id = (.*)/ || $line =~ /# newpar/ ) {
			$inpar = 1;
		} elsif ( $line =~ /# ?([a-z0-9A-Z\[\]¹_-]+) ?=? (.*)/ ) {
			$sent{$1} = $2;
		} elsif ( $line =~ /^(\d+)\t(.*)/ ) {
			placetok($line);
			$tok{$1} = $2; $tokmax = $1; 
			$tokid{$1} = $tokcnt++;	
		} elsif ( $line =~ /^(\d+)-(\d+)\t(.*)/ ) {
			# To do : mtok / dtok	
			$mtok{$1} = $3; $etok{$2} = $3; $mtoke{$1} = $2;
		} elsif ( $line =~ /^(\d+\.\d+)\t(.*)/ ) {
			# To do : non-word tokens; ignore for now (extended trees - only becomes relevant if UD integration stronger)
		} elsif ( $line =~ /^#/ ) {
			# To do : unknown comment line	
		} elsif ( $line eq '' ) {
			# End of sentence
			makeheads();
			%tok = (); %mtok = ();  %etok = ();  %tokid = ();  %sent = ();
		} else {
			print "What? ($line)"; 
		};
	};
	if ( keys %sent ) { makeheads(); }; # Add the last sentence if needed
		
};


sub placetok ($tokline) {
	# Place all attributes from the CoNLL-U token on the TEITOK token
	$tokline = @_[0];
	@flds = split("\t", $tokline ); 
	if ( $flds[9] =~ /([|]|^)tokId=([^|]+)/i ) { $tokid = $2; };
	if ( !$tokid ) { 
		push(@warning, "Token without ID in CoNLL-U input");
		return -1;
	};
	$ord2id{$flds[0]} = $tokid;
	if ( $flds[6] ne "_" ) {
		$ord2head{$flds[0]} = $flds[6];
	};
	$tok = $toklist{$tokid};
	if ( !$tok ) { 
		push(@warning, "Token not found in XML: $tokid");
		return -1;
	};
	if ( $flds[9] =~ /([|]|^)ner=([^|]+)/i ) { 
		$nerdef = $2; 
		if ( $nerdef =~ /B-(.*)/ ) {
			if ( $debug ) { print ("New NER detected: $tokid / $nerdef"); };
			$type = $1;
			$newner = $doc->createElement("name");
			push(@nerlist, $newner);
			$currner{$type} = $newner;
			$currner{$type}->setAttribute("type", $type);
			$currner{$type}->setAttribute("sameAs", "#$tokid");
		} elsif ( $nerdef =~ /I-(.*)/ ) {
			if ( $debug ) { print ("Follow-up NER detected: $tokid / $nerdef"); };
			$type = $1;
			$sameas = $currner{$type}->getAttribute("sameAs")." #$tokid";
			$currner{$type}->setAttribute("sameAs", $sameas);
		};
	};
	for ( $i=0; $i<scalar @udflds; $i++ ) {
		$key = $udflds[$i]; 
		$val = $flds[$i];
		$oval = $tok->getAttribute($key);
		if ( $key eq "word" ) { next; };
		if ( $val eq "_" ) { next; };
		if ( $oval && !$force ) { next; };
		$tok->setAttribute($key, $val);
	};
	if ( $debug ) { print $tok->toString; };
};

sub makeheads() {
	# Concert ordinal heads to ID based heads
	while ( ( $ord, $head ) = each ( %ord2head ) ) {
		$tok = $toklist{$ord2id{$ord}};
		if ( !$tok ) { 
			push(@warning, "Token not found: ".$ord2id{$ord});
			return -1;
		};
		$tok->setAttribute("head", $ord2id{$head});
		print $tok->toString;
	};
};

sub moveinside ( $node ) {
	# Move the @sameAs tokens inside
	$node = @_[0];
	$sameas = $node->getAttribute('sameAs');
	$sameas =~ s/#//g;
	@list = split(' ', $sameas);
	$tok1 = $list[0]; $tok2 = $list[-1];
	if ( !$tok1 || !$tok2 || !$toklist{$tok1} || !$toklist{$tok2} ) { push(@warning, "unable to move tokens inside NER"); return -1; };
	if ( $toklist{$list[0]}->parentNode == $toklist{$list[-1]}->parentNode ) {
		$curr = $node;
		while ( $curr->getAttribute("id") ne $list[-1] ) {
			$curr = $curr->nextSibling();
			if ( !$curr ) { push(@warning, "unable to move tokens inside NER"); return -1; };
			$node->addChild($curr);
		};
	};
};

sub textprotect ( $text ) {
	$text = @_[0];
	
	$text =~ s/&/&amp;/g;
	$text =~ s/</&lt;/g; 
	$text =~ s/>/&gt;/g;
	$text =~ s/"/&#039;/g;

	return $text;
};

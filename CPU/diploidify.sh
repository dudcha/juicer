#!/bin/bash
{
#### Description: Wrapper script to calculate diploid contact maps and accessibility tracks.
#### Usage: bash ./diploidify.sh -v|--vcf <path_to_vcf> [--separate-homologs] [-q|--mapq <mapq>] <path_to_merged_dedupped_bam_1>[ ... <path_to_merged_dedup_bam_N>].
#### Input: merged_dedup.bam file (or list of merged_dedup.bam files) from Juicer2.
#### Input (obligatory option): Phased vcf file.
#### Output: diploid hic map and diploid chromatin accessibility bw file.
#### Dependencies: Java, Samtools, GNU Parallel, KentUtils, Juicer, 3D-DNA (for diploid portion only).
#### Written by: OD

echo "*****************************************************" >&1
echo "cmd log: "$0" "$* >&1
echo "*****************************************************" >&1

USAGE="
*****************************************************
Diploidify script for ENCODE DCC hic-pipeline.

USAGE: ./diploidify.sh -v|--vcf <path_to_vcf> [-c|--chrom-sizes <path_to_chrom_sizes_file>] [-r|--resolutions resolutions_string] [--merge-homologs] [-p|--psf <path_to_psf>] [--reads-to-homologs <path_to_reads_to_homologs_file>] [-j|--juicer-dir <path_to_juicer_dir>] [-p|--phaser-dir <path_to_phaser_dir>] [-t|--threads thread_count] [-T|--threads-hic hic_thread_count] [--from-stage <stage>] [--to-stage <stage>] <path_to_merged_dedup_bam_1> ... <path_to_merged_dedup_bam_N>

DESCRIPTION:
This is a diploidify.sh script to produce diploid Hi-C maps and chromatic accessibility tracks given merged_dedup.bam(s) and a phased vcf file.

ARGUMENTS:
path_to_merged_dedup_bam
						Path to bam file containing deduplicated alignments of Hi-C reads in bam format (output by Juicer2). Multiple bam files are expected to be passed as arguments.

OPTIONS:
-h|--help
						Shows this help.

PHASING INPUT:
-v|--vcf [path_to_vcf]
						Path to a Variant Call Format (vcf) file containing phased sequence variation data, e.g. as generated by the ENCODE DCC Hi-C variant calling & phasing pipeline. Passing a vcf file invokes a diploid section of the script.

--psf [path_to_psf]
						Path to a 3D-DNA phaser psf file containing heterozygous variant and phasing information. Optional input to fast-forward some steps & save compute on processing the vcf file.

--reads-to-homologs [path_to_reads_to_homologs_file]
                        Path to a reads_to_homologs file generated by the phasing pipeline. Optional input to fast-forward some steps & save compute on diploid processing (assumes the input bams were used for phasing).

DATA FILTERING AND OUTPUT:
-c|--chrom-sizes [path_to_chrom_sizes_file or chrom_string]                         
                        Path to chrom.sizes file containing chromosomes to be phased. Can be used to remove, e.g., sex chromosomes from the list of molecules to be phased.

-q|--mapq   [mapq]
                        Mapping quality threshold to be used. Deafult: 30.

-r|--resolutions    [string]
                        Comma-separated resolutions at which to build the hic files. Default: 2500000,1000000,500000,250000,100000,50000,25000,10000,5000,2000,1000,500,200,100.

--merge-homologs
						Build one contact maps & one accessibility track with interleaved homologous chromosomes. Default: not invoked.

WORKFLOW CONTROL:
-t|--threads [num]
        				Indicate how many threads to use. Default: half of available cores as calculated by parallel --number-of-cores.

-T|--threads-hic [num]
						Indicate how many threads to use when generating the Hi-C file. Default: 24.

-j|--juicer-dir [path_to_juicer_dir]
                        Path to Juicer directory, contains scripts/, references/, and restriction_sites/

-p|--phaser-dir [path_to_3ddna_dir]
                        Path to 3D-DNA directory, contains phase/

--from-stage [pipeline_stage]
						Fast-forward to a particular stage of the pipeline. The pipeline_stage argument can be \"prep\", \"hic\", \"dhs\", \"cleanup\".

--to-stage [pipeline_stage]
						Exit after a particular stage of the pipeline. The argument can be \"prep\", \"hic\", \"dhs\", \"cleanup\".

*****************************************************
"

# defaults:
resolutionsToBuildString="-r 2500000,1000000,500000,250000,100000,50000,25000,10000,5000,2000,1000,500,200,100"
separate_homologs=true
mapq=1

# multithreading
threads=`parallel --number-of-cores`
threads=$((threads/2))
# adjust for mem usage
tmp=`awk '/MemTotal/ {threads=int($2/1024/1024/2/6-1)}END{print threads+0}' /proc/meminfo 2>/dev/null`
tmp=$((tmp+0))
([ $tmp -gt 0 ] && [ $tmp -lt $threads ]) && threads=$tmp
threadsHic=$threads

#staging
first_stage="prep"
last_stage="cleanup"
declare -A stage
stage[prep]=0
stage[hic]=1
stage[dhs]=2
stage[cleanup]=3

############### HANDLE OPTIONS ###############

while :; do
	case $1 in
		-h|--help)
			echo "$USAGE" >&1
			exit 0
        ;;
## PHASED INPUT
        -v|--vcf) OPTARG=$2
            if [ -s $OPTARG ] && [[ $OPTARG == *.vcf ]]; then
                echo "... -v|--vcf flag was triggered, will try to generate diploid versions of the hic file and accessibility track based on phasing data in $OPTARG." >&1
                vcf=$OPTARG
            else
                	echo " :( Vcf file is not found at expected location, is empty or does not have the expected extension. Exiting!" >&2
					exit 1
            fi            
            shift
        ;;
        -p|--psf) OPTARG=$2
            if [ -s $OPTARG ] && [[ $OPTARG == *.psf ]]; then
                echo "... -p|--psf flag was triggered, will try to generate diploid versions of the hic file and accessibility track based on phasing data in $OPTARG." >&1
                psf=$OPTARG
            else
                	echo " :( Psf file is not found at expected location, is empty or does not have the expected extension. Exiting!" >&2
					exit 1
            fi            
            shift
        ;;
        --reads-to-homologs) OPTARG=$2
            if [ -s $OPTARG ] && [[ $OPTARG == *.txt ]]; then
                echo "... --reads-to-homologs flag was triggered, will try to generate diploid versions of the hic file and accessibility track based on reads-to-homolog data in $OPTARG." >&1
                reads_to_homologs=$OPTARG
            else
                	echo " :( File is not found at expected location, is empty or does not have the expected extension. Exiting!" >&2
					exit 1
            fi      
            shift
        ;;
## DATA FILTERING AND OUTPUT
        --merge-homologs)
			echo "... --merge-homologs flag was triggered, will build a single diploid contact maps and accessibility track, with molecules chr1-r, chr1-a, chr2-r, chr2-a etc." >&1
			separate_homologs=false
		;;
        -c|--chrom-sizes) OPTARG=$2
            echo "... -c|--chrom-sizes flag was triggered with $OPTARG value." >&1
            if [ -s $OPTARG ] && [[ $OPTARG == *.chrom.sizes ]]; then
                chrom_sizes=$OPTARG
                chr=`awk '{str=str"|"$1}END{print substr(str,2)}' $OPTARG`
            else
                chr=$OPTARG
            fi            
            shift
        ;;
        -q|--mapq) OPTARG=$2
        	re='^[0-9]+$'
			if [[ $OPTARG =~ $re ]]; then
					echo "... -q|--mapq flag was triggered, will use $OPTARG as mapping quality threshold." >&1
					mapq=$OPTARG
			else
					echo " :( Wrong syntax for mapping quality threshold parameter value. Exiting!" >&2
					exit 1
			fi        	
        	shift
        ;;        
        -r|--resolutions) OPTARG=$2
        	echo "... -r|--resolutions flag was triggered, will build contact maps at resolutions $OPTARG." >&1
            resolutionsToBuildString="-r "$OPTARG
            shift
        ;;
## WORKFLOW
        -t|--threads) OPTARG=$2
        	re='^[0-9]+$'
			if [[ $OPTARG =~ $re ]]; then
					echo "... -t|--threads flag was triggered, will try to parallelize across $OPTARG threads." >&1
					threads=$OPTARG
			else
					echo " :( Wrong syntax for thread count parameter value. Exiting!" >&2
					exit 1
			fi        	
        	shift
        ;;
        -T|--threads-hic) OPTARG=$2
        	re='^[0-9]+$'
			if [[ $OPTARG =~ $re ]]; then
					echo "... -T|--threads-hic flag was triggered, will try to parallelize across $OPTARG threads when building hic map." >&1
					threadsHic=$OPTARG
			else
					echo " :( Wrong syntax for hic thread count parameter value. Exiting!" >&2
					exit 1
			fi        	
        	shift
        ;;
        -j|--juicer-dir) OPTARG=$2
            if [ -d $OPTARG ]; then
                echo "... -j|--juicer-dir flag was triggered with $OPTARG." >&1
                juicer_dir=$OPTARG
            else
				exit 1
                echo " :( Juicer folder not found at expected location. Exiting!" >&2
            fi    
            shift
        ;;
        -p|--phaser-dir) OPTARG=$2
            if [ -d $OPTARG ]; then
                echo "... -p|--phaser-dir flag was triggered with $OPTARG." >&1
                phaser_dir=$OPTARG
            else
				exit 1
                echo " :( Juicer folder not found at expected location. Exiting!" >&2
            fi    
            shift
        ;;
		--from-stage) OPTARG=$2
			if [ "$OPTARG" == "prep" ] || [ "$OPTARG" == "hic" ] || [ "$OPTARG" == "dhs" ] || [ "$OPTARG" == "cleanup" ]; then
        		echo "... --from-stage flag was triggered. Will fast-forward to $OPTARG." >&1
        		first_stage=$OPTARG
			else
				echo " :( Whong syntax for pipeline stage. Please use prep/hic/dhs/cleanup. Exiting!" >&2
				exit 1
			fi
			shift
        ;;
		--to-stage) OPTARG=$2
			if [ "$OPTARG" == "prep" ] || [ "$OPTARG" == "hic" ] || [ "$OPTARG" == "dhs" ] || [ "$OPTARG" == "cleanup" ]; then
				echo "... --to-stage flag was triggered. Will exit after $OPTARG." >&1
				last_stage=$OPTARG
			else
				echo " :( Whong syntax for pipeline stage. Please use prep/hic/dhs/cleanup. Exiting!" >&2
				exit 1
			fi
			shift
		;;
### utilitarian
        --) # End of all options
			shift
			break
		;;
		-?*)
			echo ":| WARNING: Unknown option. Ignoring: ${1}" >&2
		;;
		*) # Default case: If no more options then break out of the loop.
			break
	esac
	shift
done

## optional TODO: give error if diploid options are invoked without a vcf file

if [[ "${stage[$first_stage]}" -gt "${stage[$last_stage]}" ]]; then
	echo >&2 ":( Please make sure that the first stage requested is in fact an earlier stage of the pipeline to the one requested as last. Exiting!"
	exit 1
fi

############### HANDLE DEPENDENCIES ###############

## Juicer & Phaser

[ -z $juicer_dir ] && { echo >&2 ":( Juicer directory is not specified. Exiting!"; exit 1; } 
[ -z $phaser_dir ] && { echo >&2 ":( Phaser directory is not specified. Exiting!"; exit 1; } 

##	Java Dependency
type java >/dev/null 2>&1 || { echo >&2 ":( Java is not available, please install/add to path Java. Exiting!"; exit 1; }

##	GNU Parallel Dependency
type parallel >/dev/null 2>&1 || { echo >&2 ":( GNU Parallel support is set to true (default) but GNU Parallel is not in the path. Please install GNU Parallel or set -p option to false. Exiting!"; exit 1; }
[ $(parallel --version | awk 'NR==1{print $3}') -ge 20150322 ] || { echo >&2 ":( Outdated version of GNU Parallel is installed. Please install/add to path v 20150322 or later. Exiting!"; exit 1; }

## Samtools Dependency
type samtools >/dev/null 2>&1 || { echo >&2 ":( Samtools are not available, please install/add to path. Exiting!"; exit 1; }
ver=`samtools --version | awk 'NR==1{print \$NF}'`
[[ $(echo "$ver < 1.13" |bc -l) -eq 1 ]] && { echo >&2 ":( Outdated version of samtools is installed. Please install/add to path v 1.13 or later. Exiting!"; exit 1; }

## kentUtils Dependency
type bedGraphToBigWig >/dev/null 2>&1 || { echo >&2 ":( bedGraphToBigWig is not available, please install/add to path, e.g. from kentUtils. Exiting!"; exit 1; }

############### HANDLE ARGUMENTS ###############

bam=`echo "${@:1}"`
##TODO: check file extentions

([ -z $vcf ] && [ -z $psf ] && [ -z $reads_to_homologs ]) && { echo >&2 "No phased input is given to run diploidification. Please pass a vcf, psf or reads-to-homologs file. Exiting!"; exit 1; }

if [ -z $chr ]; then
    chr=`parallel --will-cite "samtools view -H {}" ::: $bam | grep "^@SQ" | sort -u | awk -F '\t' '{for(i=2;i<=NF;i++){if($i~/^SN:/){str=str"|"substr($i,4)}}}END{print substr(str,2)}'`
fi

if [ -z $chrom_sizes ]; then
    parallel --will-cite "samtools view -H {}" ::: $bam | grep "^@SQ" | sort -u | awk -F '\t' -v chr=$chr 'BEGIN{n=split(chr,tmp,"|"); for(i in tmp){chrom["SN:"tmp[i]]=1}}($2 in chrom){len[$2]=substr($3,4)}END{for(i=1;i<=n;i++){print tmp[i]"\t"len["SN:"tmp[i]]}}' > tmp.chrom.sizes
    chrom_sizes="tmp.chrom.sizes"
fi


############### MAIN #################
## 0. PREP BAM FILE

if [ "$first_stage" == "prep" ]; then

	echo "...Extracting unique paired alignments from bams and sorting..." >&1

	# make header for the merged file pipe
	parallel --will-cite "samtools view -H {} > {}_header.bam" ::: $bam
	header_list=`parallel --will-cite "printf %s' ' {}_header.bam" ::: $bam`
	samtools merge --no-PG -f mega_header.bam ${header_list}
	rm ${header_list}

	samtools cat -@ $((threads * 2)) -h mega_header.bam $bam | samtools view -u -d "rt:0" -d "rt:1" -d "rt:2" -d "rt:3" -d "rt:4" -d "rt:5" -@ $((threads * 2)) -F 0x400 -q $mapq - |  samtools sort -@ $threads -m 6G -o reads.sorted.bam
	[ `echo "${PIPESTATUS[@]}" | tr -s ' ' + | bc` -eq 0 ] || { echo ":( Pipeline failed at bam sorting. See stderr for more info. Exiting!" | tee -a /dev/stderr && exit 1; }
	rm mega_header.bam

	samtools index -@ $threads reads.sorted.bam	
	[ $? -eq 0 ] || { echo ":( Failed at bam indexing. See stderr for more info. Exiting!" | tee -a /dev/stderr && exit 1; }		
	# e.g. will fail with chr longer than ~500Mb. Use samtools index -c -m 14 reads.sorted.bam

	echo ":) Done extracting unique paired alignments from bam and sorting." >&1

	[ "$last_stage" == "prep" ] && { echo "Done with the requested workflow. Exiting after prepping bam!"; exit; }
	first_stage="hic"

fi

## IV. BUILD DIPLOID CONTACT MAPS
if [ "$first_stage" == "hic" ]; then

	echo "...Building diploid contact maps from reads overlapping phased SNPs..." >&1

	if [ ! -s reads.sorted.bam ] || [ ! -s reads.sorted.bam.bai ] ; then
		echo ":( Files from previous stages of the pipeline appear to be missing. Exiting!" | tee -a /dev/stderr
		exit 1
	fi

    if [ -z $reads_to_homologs ]; then

        if [ -z $psf ]; then
            echo "  ... Parsing vcf..."
            awk -v chr=${chr} -v output_prefix="out" -f ${phaser_dir}/phase/vcf-to-psf-and-assembly.awk ${vcf}
            echo "  ... :) Done parsing vcf!"
            psf=out.psf
            rm out.assembly
        fi

        echo "  ... Extracting reads overlapping SNPs..."
        export SHELL=$(type -p bash)
		export psf=${psf}
		export pipeline=${phaser_dir}
		doit () { 
			samtools view -@ 2 reads.sorted.bam $1 | awk -f ${pipeline}/phase/extract-SNP-reads-from-sam-file.awk ${psf} -
		}
		export -f doit
		echo $chr | tr "|" "\n" | parallel -j $threads --will-cite --joblog temp.log doit > dangling.sam
		exitval=`awk 'NR>1{if($7!=0){c=1; exit}}END{print c+0}' temp.log`
		[ $exitval -eq 0 ] || { echo ":( Pipeline failed at parsing bam. Check stderr for more info. Exiting! " | tee -a /dev/stderr && exit 1; }
		rm temp.log

        bash ${phaser_dir}/phase/assign-reads-to-homologs.sh -t ${threads} -c ${chr} $psf dangling.sam
        reads_to_homologs=reads_to_homologs.txt
        echo "  ... :) Done extracting reads overlapping SNPs!"

    fi

    # build mnd file: can do without sort -n, repeat what was done in hic stage.
    export SHELL=$(type -p bash)
	export psf=${psf}
	export pipeline=${phaser_dir}
    export reads_to_homologs=$reads_to_homologs
    doit () { 
        samtools view -@ 2 -h reads.sorted.bam $1 | awk -v chr=$1 'BEGIN{OFS="\t"}FILENAME==ARGV[1]{if($2==chr"-r"||$2==chr"-a"){if(keep[$1]&&keep[$1]!=$2){delete keep[$1]}else{keep[$1]=$2}};next}$0~/^@SQ/{$2=$2"-r"; print; $2=substr($2,1,length($2)-2)"-a"; print; next}$0~/^@/{print; next}($1 in keep)&&($7=="="||$7=="*"){$3=keep[$1];print}' $reads_to_homologs - | samtools sort -n -m 1G -O sam | awk '$0~/^@/{next}($1!=prev){if(n==2){sub("\t","",str); print str}; str=""; n=0}{for(i=12;i<=NF;i++){if($i~/^ip:i:/){$4=substr($i,6);break;}};str=str"\t"n"\t"$3"\t"$4"\t"n; n++; prev=$1}END{if(n==2){sub("\t","",str); print str}}' | sort -k 2,2 -S 6G
    }
    export -f doit
    echo $chr | tr "|" "\n" | parallel -j $threads --will-cite --joblog temp.log -k doit > diploid.mnd.txt
    exitval=`awk 'NR>1{if($7!=0){c=1; exit}}END{print c+0}' temp.log`
    [ $exitval -eq 0 ] || { echo ":( Pipeline failed at building diploid contact maps. See stderr for more info. Exiting! " | tee -a /dev/stderr && exit 1; }
    rm temp.log

    export IBM_JAVA_OPTIONS="-Xmx100000m -Xgcthreads24"
    export _JAVA_OPTIONS="-Xmx100000m -Xms100000m"

    # build hic file(s)
    if [ "$separate_homologs" == "true" ]; then
		{ awk '$2~/-r$/{gsub("-r","",$2); gsub("-r","",$6); print}' diploid.mnd.txt > tmp1.mnd.txt && "${juicer_dir}"/scripts/juicer_tools pre -n "$resolutionsToBuildString" tmp1.mnd.txt "diploid_inter_r.hic" ${chrom_sizes}; "${juicer_dir}"/scripts/juicer_tools addNorm diploid_inter_r.hic -k VC,VC_SQRT; }
        { awk '$2~/-a$/{gsub("-a","",$2); gsub("-a","",$6); print}' diploid.mnd.txt > tmp2.mnd.txt && "${juicer_dir}"/scripts/juicer_tools pre -n "$resolutionsToBuildString" tmp2.mnd.txt "diploid_inter_a.hic" ${chrom_sizes}; "${juicer_dir}"/scripts/juicer_tools addNorm diploid_inter_a.hic -k VC,VC_SQRT; }
		rm tmp1.mnd.txt tmp2.mnd.txt
		## TODO: check if successful
	else
		"${juicer_dir}"/scripts/juicer_tools pre -n "$resolutionsToBuildString" diploid.mnd.txt "diploid_inter.hic" <(awk 'BEGIN{OFS="\t"}{print $1"-r", $2; print $1"-a", $2}' ${chrom_sizes})
        "${juicer_dir}"/scripts/juicer_tools addNorm diploid_inter.hic -k VC,VC_SQRT
		## TODO: check if successful
	fi

	echo ":) Done building diploid contact maps from reads overlapping phased SNPs." >&1
	
	[ "$last_stage" == "hic" ] && { echo "Done with the requested workflow. Exiting after building diploid contact maps!"; exit; }
	first_stage="dhs"

fi

## V. BUILD DIPLOID ACCESSIBILITY TRACKS
if [ "$first_stage" == "dhs" ]; then

	echo "...Building diploid accessibility tracks from reads overlapping phased SNPs..." >&1

	if [ ! -s reads.sorted.bam ] || [ ! -s reads.sorted.bam.bai ] || [ -z $reads_to_homologs ] || [ ! -s $reads_to_homologs ]; then
		echo ":( Files from previous stages of the pipeline appear to be missing. Exiting!" | tee -a /dev/stderr
		exit 1
	fi

    ## figure out platform
    pl=`samtools view -H reads.sorted.bam | grep '^@RG' | sed "s/.*PL:\([^\t]*\).*/\1/g" | sed "s/ILM/ILLUMINA/g;s/Illumina/ILLUMINA/g;s/LS454/454/g" | uniq`
	([ "$pl" == "ILLUMINA" ] || [ "$pl" == "454" ]) || { echo ":( Platform name is not recognized or data from different platforms seems to be mixed. Can't handle this case. Exiting!" | tee -a /dev/stderr && exit 1; }
	[ "$pl" == "ILLUMINA" ] && junction_rt_string="-d rt:2 -d rt:3 -d rt:4 -d rt:5" || junction_rt_string="-d rt:0 -d rt:1"

    export SHELL=$(type -p bash)
    export junction_rt_string=${junction_rt_string}
    export reads_to_homologs=${reads_to_homologs}
    doit () {
samtools view -@2 ${junction_rt_string} -h reads.sorted.bam $1 | awk -v chr=$1 'BEGIN{
        OFS="\t"}FILENAME==ARGV[1]{
                if($2==chr"-r"||$2==chr"-a"){
                        if(keep[$1]&&keep[$1]!=$2){
                                delete keep[$1]
                        }else{
                                keep[$1]=$2;
                                if ($3%2==0){
                                        keepRT[$1 " " $3+1]=1;
                                } else{
                                        keepRT[$1 " " $3-1]=1;
                                }
                        }
                };
                next
        }
        $0~/^@/{next}
        ($1 in keep){
                $3=keep[$1];                 
                for (i=12; i<=NF; i++) {
                        if ($i~/^ip/) {
                                split($i, ip, ":");
                        }
                        else if ($i ~ /^rt:/) {
                                split($i, rt, ":");
                        }
                }
                raw_locus[$3" "ip[3]]++
                if (keepRT[$1" "rt[3]]) {
                        locus[$3" "ip[3]]++;
                }
        }END{
                for (i in raw_locus) {
                    split(i, a, " ")
                        print a[1], a[2]-1, a[2], raw_locus[i]
                }
                for (i in locus) {
                        split(i, a, " "); 
                        print a[1], a[2]-1, a[2], locus[i] > "/dev/stderr"
                }
        }' ${reads_to_homologs} -
}

    export -f doit
    awk '{print $1}' $chrom_sizes | parallel -j $threads --will-cite --joblog temp.log -k doit >tmp_raw.bedgraph 2>tmp_corrected.bedgraph

    exitval=`awk 'NR>1{if($7!=0){c=1; exit}}END{print c+0}' temp.log`
	[ $exitval -eq 0 ] || { echo ":( Pipeline failed at building diploid contact maps. See stderr for more info. Exiting! " | tee -a /dev/stderr && exit 1; }
	rm temp.log

    sort -k1,1 -k2,2n -S6G --parallel=${threads} tmp_raw.bedgraph > tmp_raw.bedgraph.sorted && mv tmp_raw.bedgraph.sorted tmp_raw.bedgraph
    sort -k1,1 -k2,2n -S6G --parallel=${threads} tmp_corrected.bedgraph > tmp_corrected.bedgraph.sorted && mv tmp_corrected.bedgraph.sorted tmp_corrected.bedgraph

    # build bw file(s)
    if [ "$separate_homologs" == "true" ]; then
        awk 'BEGIN{OFS="\t"}$1~/-r$/{$1=substr($1,1,length($1)-2); print}' tmp_raw.bedgraph > tmp1.bedgraph
        bedGraphToBigWig tmp1.bedgraph ${chrom_sizes} diploid_inter_raw_r.bw && rm tmp1.bedgraph
        awk 'BEGIN{OFS="\t"}$1~/-a$/{$1=substr($1,1,length($1)-2); print}' tmp_raw.bedgraph > tmp2.bedgraph
        bedGraphToBigWig tmp2.bedgraph ${chrom_sizes} diploid_inter_raw_a.bw && rm tmp2.bedgraph

        awk 'BEGIN{OFS="\t"}$1~/-r$/{$1=substr($1,1,length($1)-2); print}' tmp_corrected.bedgraph > tmp1.bedgraph
        bedGraphToBigWig tmp1.bedgraph ${chrom_sizes} diploid_inter_corrected_r.bw && rm tmp1.bedgraph
        awk 'BEGIN{OFS="\t"}$1~/-a$/{$1=substr($1,1,length($1)-2); print}' tmp_corrected.bedgraph > tmp2.bedgraph
        bedGraphToBigWig tmp2.bedgraph ${chrom_sizes} diploid_inter_corrected_a.bw && rm tmp2.bedgraph
		## TODO: check if successful
	else
        bedGraphToBigWig tmp_raw.bedgraph <(awk 'BEGIN{OFS="\t"}{print $1"-r", $2; print $1"-a", $2}' ${chrom_sizes}) diploid_inter_raw.bw
        bedGraphToBigWig tmp_corrected.bedgraph <(awk 'BEGIN{OFS="\t"}{print $1"-r", $2; print $1"-a", $2}' ${chrom_sizes}) diploid_inter_corrected.bw
	fi

    #rm tmp_raw.bedgraph tmp_corrected.bedgraph

    echo ":) Done building diploid accessibility tracks from reads overlapping phased SNPs." >&1

	[ "$last_stage" == "dhs" ] && { echo "Done with the requested workflow. Exiting after building diploid accessibility tracks!"; exit; }
	first_stage="cleanup"

fi

# ## IX. CLEANUP
# 	echo "...Starting cleanup..." >&1
# 	#rm reads.sorted.bam reads.sorted.bam.bai
# 	#rm reads_to_homologs.txt
#   rm -f tmp.chrom.sizes
#   rm -f diploid.mnd.txt out.psf dangling.sam
#   rm tmp_raw.bedgraph tmp_corrected.bedgraph
# 	echo ":) Done with cleanup. This is the last stage of the pipeline. Exiting!"
# 	exit

}

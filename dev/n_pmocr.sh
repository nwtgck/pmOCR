#!/usr/bin/env bash

PROGRAM="pmocr" # Automatic OCR service that monitors a directory and launches a OCR instance as soon as a document arrives
AUTHOR="(L) 2015 by Orsiris \"Ozy\" de Jong"
CONTACT="http://www.netpower.fr - ozy@netpower.fr"
PROGRAM_VERSION=1.3-dev
PROGRAM_BUILD=2016030303

## Instance identification (used for mails only)
INSTANCE_ID=MyOCRServer

## OCR Engine (can be tesseract or abbyyocr11)
OCR_ENGINE=abbyyocr11

## List of allowed extensions for input files
FILES_TO_PROCES="\(pdf\|tif\|tiff\|png\|jpg\|jpeg\|bmp\|pcx\|dcx\)"

##### THE FOLLOWING PARAMETERS ARE USED WHEN pmOCR IS RUN AS SERVICE

## List of alert mails separated by spaces Default log file until config file is loaded
DESTINATION_MAILS="infrastructure@example.com"

## Directories to monitor (Leave variables empty in order to disable specific monitoring).
## As of today, Tesseract only handles PDF
PDF_MONITOR_DIR="/storage/service_ocr/PDF"
WORD_MONITOR_DIR="/storage/service_ocr/WORD"
EXCEL_MONITOR_DIR="/storage/service_ocr/EXCEL"
CSV_MONITOR_DIR="/storage/service_ocr/CSV"

## Adds the following suffix to OCRed files (ex: input.tiff becomes input_OCR.pdf). Any file containing this suffix will be ignored.
FILENAME_SUFFIX="_OCR"

## Delete original file upon successful OCR
DELETE_ORIGINAL=no
## If file is not deleted, add a suffix so it won't be processed again. This suffix is added toghether with FILENAME_SUFFIX.
NO_DELETE_SUFFIX="_NO"

# Alternative check if PDFs are already OCRed (checks if a pdf contains a font). This will prevent images integrated in already indexed PDFs to get OCRed.
CHECK_PDF=yes

## Add some extra info to the filename. Example here adds a pseudo ISO 8601 timestamp after a dot (pseudo because the colon sign would render the filename quite weird).
## Keep variables between singlequotes if you want them to expand at runtime. Leave this variable empty if you don't want to add anything.
FILENAME_ADDITION='.$(date --utc +"%Y-%m-%dT%H-%M-%SZ")'

# Wait a trivial number of seconds before launching OCR
WAIT_TIME=1

if [ "$OCR_ENGINE" == "tesseract" ]; then
# tesseract 3.x Engine Arguments
################################
## tesseract arguments settings :
## Pay attention this is configured to french here
OCR_ENGINE_EXEC=/usr/bin/tesseract
PDF_OCR_ENGINE_ARGS='pdf'
OCR_ENGINE_INPUT_ARG='-l eng' # Language setting
OCR_ENGINE_OUTPUT_ARG=
elif [ "$OCR_ENGINE" == "abbyyocr11" ]; then
# OCR Engine Arguments
###############################
## ABBYYOCR arguments settings :
## lpp = load predefinied profil / TextExtraction_Acuraccy = name of the predefinied profile / -adb = Detect barcodes / -ido = Detect and rotate image orientation / -adtop = Detect text embedded in images
## -rl = List of languages for the document (French,English,Spanish ) / recc = Enhanced character confidence
##
##### PDF related arguments : -pfs = PDF Export preset (balanced) / -pacm = PDF/A standards (pdfa-3a) / ptem = Specifies the mode of export of recognized text into PDF (PDF/A) format.
##### DOCX related arguments :-dheb  = Highlights uncertainly recognized characters with the background color when exporting to DOCX format.(color definied by deb parameter) 
##### -deb 0xFFFF00 (yellow highlights) /
##### XLSX related arguments :  -xlto = only export text from table / -xlrf = remove formating from text / -xllrm = This option allows setting the mode of retaining the original document tables' layout in the output XLSX file (Default, ExactDocument, ExactLines) 

## Full path to OCR engine
OCR_ENGINE_EXEC=/usr/local/bin/abbyyocr11
PDF_OCR_ENGINE_ARGS='-lpp TextExtraction_Accuracy -adb -ido -adtop -rl French,English,Spanish -recc -pfs Balanced -pacm Pdfa_3a -ptem ImageOnText -f pdf'
WORD_OCR_ENGINE_ARGS='-lpp TextExtraction_Accuracy -adb -ido -adtop -rl French,English,Spanish -recc -f docx'
EXCEL_OCR_ENGINE_ARGS=' -lpp TextExtraction_Accuracy -adb -ido -adtop -rl French,English,Spanish -recc -rpihp -xlrf -xllrm ExactLines -f xlsx'
CSV_OCR_ENGINE_ARGS='-lpp TextExtraction_Accuracy -adb -ido -adtop -rl French,English,Spanish -recc -trl -f TextUnicodeDefaults'
OCR_ENGINE_INPUT_ARG='-if'
OCR_ENGINE_OUTPUT_ARG='-of'
fi

PDF_EXTENSION=".pdf"
WORD_EXTENSION=".docx"
EXCEL_EXTENSION=".xlsx"
CSV_EXTENSION=".csv"

#### DO NOT EDIT UNDER THIS LINE ##########################################################################################################################

source "./ofunctions.sh"

function CheckEnvironment {
	if ! type -p $OCR_ENGINE_EXEC > /dev/null 2>&1
	then
		Logger "$OCR_ENGINE_EXEC not present." "CRITICAL"
		exit 1
	fi

	if [ $_SERVICE_RUN -eq 1 ]; then
		if ! type -p inotifywait > /dev/null 2>&1
		then
			Logger "inotifywait not present (see inotify-tools package ?)." "CRITICAL"
			exit 1
		fi

		if ! type -p pgrep > /dev/null 2>&1
		then
			Logger "pgrep not present." "CRITICAL"
			exit 1
		fi

		if [ "$PDF_MONITOR_DIR" != "" ]; then
			if [ ! -w "$PDF_MONITOR_DIR" ]; then
				Logger "Directory [$PDF_MONITOR_DIR] not writable." "ERROR"
				exit 1
			fi
		fi

		if [ "$WORD_MONITOR_DIR" != "" ]; then
			if [ ! -w "$WORD_MONITOR_DIR" ]; then
				Logger "Directory [$WORD_MONITOR_DIR] not writable." "ERROR"
				exit 1
			fi
		fi

		if [ "$EXCEL_MONITOR_DIR" != "" ]; then
			if [ ! -w "$EXCEL_MONITOR_DIR" ]; then
				Logger "Directory [$EXCEL_MONITOR_DIR] not writable." "ERROR"
				exit 1
			fi
		fi

		if [ "$CSV_MONITOR_DIR" != "" ]; then
			if [ ! -w "$CSV_MONITOR_DIR" ]; then
				Logger "Directory [$CSV_MONITOR_DIR] not writable." "ERROR"
				exit 1
			fi
		fi
	fi

	if [ "$CHECK_PDF" == "yes" ] && ( [ $_SERVICE_RUN -eq 1 ] || [ $_BATCH_RUN -eq 1 ])
	then
		if ! type -p pdffonts > /dev/null 2>&1
		then
			Logger "pdffonts not present (see poppler-utils package ?)." "CRITICAL"
		exit 1
		fi
	fi
}

function TrapQuit {
	KillChilds $$ > /dev/null 2>&1
	Logger "Service $PROGRAM stopped instance $$." "NOTICE"
	exit
}

function WaitForIt {
	while ps -p $1 > /dev/null 2>&1
	do
		sleep $WAIT_TIME
	done
}

function OCR_service {
	## Function arguments

	DIRECTORY_TO_PROCESS="$1" 	#(contains some path)
	FILE_EXTENSION="$2" 		#(filename endings to exclude from processing)
	OCR_ENGINE_ARGS="$3" 		#(transformation specific arguments)
	CSV_HACK="$4" 			#(CSV transformation flag)

	while true
	do
		inotifywait --exclude "(.*)$FILENAME_SUFFIX$FILE_EXTENSION" -qq -r -e create "$DIRECTORY_TO_PROCESS" &
		WaitForIt $!
		sleep $WAIT_TIME
		OCR "$DIRECTORY_TO_PROCESS" "$FILE_EXTENSION" "$OCR_ENGINE_ARGS" "$CSV_HACK"
	done
}


function OCR {
	## Function arguments

	DIRECTORY_TO_PROCESS="$1" 	#(contains some path)
	FILE_EXTENSION="$2" 		#(filename extension for excludes and output)
	OCR_ENGINE_ARGS="$3" 		#(transformation specific arguments)
	CSV_HACK="$4" 			#(CSV transformation flag)

		## CHECK find excludes
		if [ "$FILENAME_SUFFIX" != "" ]; then
			find_excludes="*$FILENAME_SUFFIX$FILE_EXTENSION"
		else
			find_excludes=""
		fi

		if [ "$OCR_ENGINE" == "abbyyocr11" ]; then
			# full exec syntax for xargs arg: sh -c 'export local_var="{}"; eval "some stuff '"$SCRIPT_VARIABLE"' other stuff \"'"$SCRIPT_VARIABLE_WITH_SPACES"'\" \"$internal_variable\""'
			find "$DIRECTORY_TO_PROCESS" -type f -iregex ".*\.$FILES_TO_PROCES" ! -name "$find_excludes" -print0 | xargs -0 -I {} bash -c 'export file="{}"; function proceed { eval "\"'"$OCR_ENGINE_EXEC"'\" '"$OCR_ENGINE_INPUT_ARG"' \"$file\" '"$OCR_ENGINE_ARGS"' '"$OCR_ENGINE_OUTPUT_ARG"' \"${file%.*}'"$FILENAME_ADDITION""$FILENAME_SUFFIX$FILE_EXTENSION"'\" && if [ '"$_BATCH_RUN"' -eq 1 ] && [ '"$_SILENT"' -ne 1 ];then echo \"Processed $file\"; fi && echo -e \"$(date) - Processed $file\" >> '"$LOG_FILE"' && if [ '"$DELETE_ORIGINAL"' == \"yes\" ]; then rm -f \"$file\"; else mv \"$file\" \"${file%.*}'"$NO_DELETE_SUFFIX$FILENAME_SUFFIX"'.${file##*.}\"; fi"; }; if [ "'$CHECK_PDF'" == "yes" ]; then if [ $(pdffonts "$file" 2> /dev/null | wc -l) -lt 3 ]; then proceed; else echo "$(date) - Skipping file $file already containing text." >> '"$LOG_FILE"'; fi; else proceed; fi'
			if [ $? != 0 ]; then
				Logger "Could not process [$DIRECTORY_TO_PROCESS] with [$OCR_ENGINE]." "ERROR"
				SendAlert
			fi

			if [ "$CSV_HACK" == "txt2csv" ]; then
				## Replace all occurences of 3 spaces or more by a semicolor (since Abbyy does a better doc to TXT than doc to CSV, ugly hack i know)
				find "$DIRECTORY_TO_PROCESS" -type f -name "*$FILENAME_SUFFIX$FILE_EXTENSION" -print0 | xargs -0 -I {} sed -i 's/   */;/g' "{}"
				if [ $? != 0 ]; then
					Logger "Could not process [$DIRECTORY_TO_PROCESS] with [$OCR_ENGINE]." "ERROR"
					SendAlert
				fi

			fi
		elif [ "$OCR_ENGINE" == "tesseract" ]; then
			find "$DIRECTORY_TO_PROCESS" -type f -iregex ".*\.$FILES_TO_PROCES" ! -name "$find_excludes" -print0 | xargs -0 -I {} bash -c 'export file="{}"; function proceed { eval "\"'"$OCR_ENGINE_EXEC"'\" '"$OCR_ENGINE_INPUT_ARG"' \"$file\" '"$OCR_ENGINE_OUTPUT_ARG"' \"${file%.*}'"$FILENAME_ADDITION""$FILENAME_SUFFIX"'\" '"$OCR_ENGINE_ARGS"' && if [ '"$_BATCH_RUN"' -eq 1 ] && [ '"$_SILENT"' -ne 1 ];then echo \"Processed $file\"; fi && echo -e \"$(date) - Processed $file\" >> '"$LOG_FILE"' && if [ '"$DELETE_ORIGINAL"' == \"yes\" ]; then rm -f \"$file\"; else mv \"$file\" \"${file%.*}'"$NO_DELETE_SUFFIX$FILENAME_SUFFIX"'.${file##*.}\"; fi"; }; if [ "'$CHECK_PDF'" == "yes" ]; then if [ $(pdffonts "$file" 2> /dev/null | wc -l) -lt 3 ]; then proceed; else echo "$(date) - Skipping file $file already containing text." >> '"$LOG_FILE"'; fi; else proceed; fi'
			if [ $? != 0 ]; then
				Logger "Could not process [$DIRECTORY_TO_PROCESS] with [$OCR_ENGINE]." "ERROR"
				SendAlert
			fi
		fi
}

function Usage {
	echo ""
	echo "$PROGRAM $PROGRAM_VERSION $PROGRAM_BUILD"
	echo "$AUTHOR"
	echo "$CONTACT"
	echo ""
	echo "$PROGRAM can be launched as a directory monitoring service using \"service $PROGRAM-srv start\" or in batch processing mode"
	echo "Batch mode usage:"
	echo "$PROGRAM.sh --batch [options] /path/to/folder"
	echo ""
	echo "[OPTIONS]"
	echo "-p, --target=PDF		Creates a PDF document"
	echo "-w, --target=DOCX		Creates a WORD document"
	echo "-e, --target=XLSX		Creates an EXCEL document"
	echo "-c, --target=CSV		Creates a CSV file"
	echo "(multiple targets can be set)"
	echo ""
	echo "-k, --skip-txt-pdf	Skips PDF files already containing indexable text"
	echo "-d, --delete-input	Deletes input file after processing ( preventing them to be processed again)"
	echo "--suffix=...		Adds a given suffix to the output filename (in order to not process them again, ex: pdf to pdf conversion)."
	echo "				By default, the suffix is '_OCR'"
	echo "--no-suffix		Won't add any suffix to the output filename"
	echo "--text=...		Adds a given text / variable to the output filename (ex: --add-text='$(date +%Y)').
					By default, the text is the conversion date in pseudo ISO format."
	echo "--no-text			Won't add any text to the output filename"
	echo "-s, --silent		Will not output anything to stdout"
	echo ""
	exit 128
}

#### Program Begin

_VERBOSE=0
_SILENT=0
skip_txt_pdf=0
delete_input=0
suffix="_OCR"
no_suffix=0
no_text=0
_BATCH_RUN=0
_SERVICE_RUN=0

for i in "$@"
do
	case $i in
		--batch)
		_BATCH_RUN=1
		;;
		--service)
		_SERVICE_RUN=1
		;;
		--silent|-s)
		_SILENT=1
		;;
		-p|--target=pdf|--target=PDF)
		pdf=1
		;;
		-w|--target=DOCX|--target=docx)
		docx=1
		;;
		-e|--target=XLSX|--target=xlsx)
		xlsx=1
		;;
		-c|--target=CSV|--target=csv)
		csv=1
		;;
		-k|--skip-txt-pdf)
		skip_txt_pdf=1
		;;
		-d|--delete-input)
		delete_input=1
		;;
		--suffix=*)
		suffix=${i##*=}
		;;
		--no-suffix)
		no_suffix=1
		;;
		--text=*)
		text=${i##*=}
		;;
		--no-text)
		no_text=1
		;;
		--help|-h|--version|-v|-?)
		Usage
		;;
	esac
done

if [ $_BATCH_RUN -eq 1 ]; then
	if [ $skip_txt_pdf -eq 1 ]; then
		CHECK_PDF="yes"
	else
		CHECK_PDF="no"
	fi

	if [ $no_suffix -eq 1 ]; then
		FILENAME_SUFFIX=""
	elif [ "$suffix" != "" ]; then
		FILENAME_SUFFIX="$suffix"
	fi

	if [ $no_text -eq 1 ]; then
		FILENAME_ADDITION=""
	elif [ "$text" != "" ]; then
		FILENAME_ADDITION="$text"
	fi

	if [ $delete_input -eq 1 ]; then
		DELETE_ORIGINAL=yes
	else
		DELETE_ORIGINAL=no
	fi
fi

if [ "$OCR_ENGINE" != "tesseract" ] && [ "$OCR_ENGINE" != "abbyyocr11" ]; then
	LogError "No valid OCR engine selected"
	exit 1
fi

CheckEnvironment

if [ $_SERVICE_RUN -eq 1 ]; then
	trap TrapQuit SIGTERM EXIT SIGKILL SIGHUP SIGQUIT

	if [ "$PDF_MONITOR_DIR" != "" ]; then
		OCR_service "$PDF_MONITOR_DIR" "$PDF_EXTENSION" "$PDF_OCR_ENGINE_ARGS" &
		child_ocr_pid_pdf=$!
	fi

	if [ "$WORD_MONITOR_DIR" != "" ]; then
		OCR_service "$WORD_MONITOR_DIR" "$WORD_EXTENSION" "$WORD_OCR_ENGINE_ARGS" &
		child_ocr_pid_word=$!
	fi

	if [ "$EXCEL_MONITOR_DIR" != "" ]; then
		OCR_service "$EXCEL_MONITOR_DIR" "$EXCEL_EXTENSION" "$EXCEL_OCR_ENGINE_ARGS" &
		child_ocr_pid_excel=$!
	fi

	if [ "$CSV_MONITOR_DIR" != "" ]; then
		OCR_service "$CSV_MONITOR_DIR" "$CSV_EXTENSION" "$CSV_OCR_ENGINE_ARGS" "txt2csv" &
		child_ocr_pid_csv=$!
	fi

	Logger "Service $PROGRAM instance $$ started as $LOCAL_USER on $LOCAL_HOST." "NOTICE"

	while true
	do
		sleep $WAIT_TIME
	done
elif [ $_BATCH_RUN -eq 1 ]; then
	if [ "$pdf" != "1" ] && [ "$docx" != "1" ] && [ "$xlsx" != "1" ] && [ "$csv" != "1" ]; then
		Logger "No output format chosen." "ERROR"
		Usage
	fi

	# Get last argument that should be a path
	eval batch_path=\${$#}
	if [ ! -d "$batch_path" ]; then
		Logger "Missing path." "ERROR"
		Usage
	fi

	if [ "$pdf" == 1 ]; then
		Logger "Beginning PDF OCR recognition of $batch_path" "NOTICE"
		OCR "$batch_path" "$PDF_EXTENSION" "$PDF_OCR_ENGINE_ARGS"
		Logger "Process ended." "NOTICE"
	fi

	if [ "$docx" == 1 ]; then
		Logger "Beginning DOCX OCR recognition of $batch_path" "NOTICE"
		OCR "$batch_path" "$WORD_EXTENSION" "$WORD_OCR_ENGINE_ARGS"
		Logger "Batch ended." "NOTICE"
	fi

	if [ "$xlsx" == 1 ]; then
		Logger "Beginning XLSX OCR recognition of $batch_path" "NOTICE"
		OCR "$batch_path" "$EXCEL_EXTENSION" "$EXCEL_OCR_ENGINE_ARGS"
		Logger "batch ended." "NOTICE"
	fi

	if [ "$csv" == 1 ]; then
		Logger "Beginning CSV OCR recognition of $batch_path" "NOTICE"
		OCR "$batch_path" "$CSV_EXTENSION" "$CSV_OCR_ENGINE_ARGS" "txt2csv"
		Logger "Batch ended." "NOTICE"
	fi

else
	Logger "$PROGRAM must be run as a system service or in batch mode." "ERROR"
	Usage
fi

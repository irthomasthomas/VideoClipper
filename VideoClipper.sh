trap clean_up EXIT #SIGHUP SIGINT SIGTERM

# if [[ ! -f /tmp/ramdisk/test ]]; then
#   source /home/thomas/Development/scripts/mkramdisk.sh
#   touch /tmp/ramdisk/test
# fi

welcome_message="This script takes an video file and extracts a section using ffmpeg keyframes."
usage_string="Enter a video Filepath, Start-time, and End-time as 00:00:00."
filepath_error_string="$1 Does not appear to be a valid filepath. Run the script again with the full-path to an  as the first parameter."
time_input_error="The Start and End time parameters where not entered correctly."

function initialise_file_tags() {
  # Error /run/user/1000/kio-fuse-*/tags/ does not exist. How can we consistently get the tags directory?
  # https://github.com/kde/kio-fuse/issues/4
  dolphin tags:/ &
  xdg_open_pid=$!
  sleep 0.2
  kill $xdg_open_pid
}

function get_system_tags() {
    tags_dir="/run/user/"$(id -u)"/kio-fuse-*/tags"
    local system_tags=()
    system_tags+=("New_Tag")
    system_tags+=("Previous_Tags")
    for tag in $tags_dir/*; do
      tag_name=$(basename $tag)
      system_tags+=("$tag_name")
    done
    echo "${system_tags[@]}"
}

function get_initial_tags() {
  local system_tags=("$@")
  local file_tags

  file_tags=$(getfattr -n user.xdg.tags --only-values "$FILEPATH")

  local arg_list=""
  local index=1
  for tag in "${system_tags[@]}"; do
    if [[ $file_tags =~ $tag ]]; then
      arg_list="$arg_list $index $tag on"
    else
      arg_list="$arg_list $index $tag off"
    fi
    index=$((index + 1))
  done
  echo "$arg_list"
}

function select_tags() {
  local FILEPATH="$1"
  local file_tags
  local selected_indexes
  local previous_selected
  local system_tags=($(get_system_tags))

  all_tags_args=$(get_initial_tags "${system_tags[@]}")

  sleep 0.2
  selected_indexes=$(kdialog --checklist "Select tags:" $all_tags_args)
  if [[ $? = 1 ]]; then
    exit
  fi

  selected_indexes=$(echo $selected_indexes | tr -d '"')
  for index in $selected_indexes; do
    tag="${system_tags[$((index - 1))]}"
    if [[ "$tag" == "New_Tag" ]]; then
      new_tag=$(kdialog --inputbox "Enter new tag name:")
      if [[ $? = 1 ]]; then
        exit
      fi
      file_tags="$file_tags,$new_tag"
    elif [[ "$tag" == "Previous_Tags" ]]; then
      previous_selected=1
    else
      file_tags="$file_tags,$tag"
    fi
  done
  file_tags=${file_tags#*,}
  if [[ $previous_selected == 1 ]]; then
    metadata_tags="resolution/$resolution,pix_fmt/$pix_fmt,color_space/$color_space,video_profile/$profile,color_transfer/$color_transfer,color_primaries/$color_primaries,FPS/$fps"
    tags_to_set="$file_tags,$previous_tags,$metadata_tags"
#    tags_to_set=${file_tags#*,}
  else
    metadata_tags="resolution/$resolution,pix_fmt/$pix_fmt,color_space/$color_space,video_profile/$profile,color_transfer/$color_transfer,color_primaries/$color_primaries,FPS/$fps"
    tags_to_set="$file_tags,$metadata_tags"
#    tags_to_set=${tags_to_set#*,}
  fi
  setfattr -n user.xdg.tags -v "$tags_to_set" "$FILEPATH"
  echo  "$file_tags"
}

function extract_metadata() {
  width=$(echo "$metadata" | jq -r '.width')
  if [[ $width == 5120 ]]; then
    resolution="5.1k"
  elif [[ $width == 4096 ]]; then
    resolution="4K-DCI"
  elif [[ $width == 3840 ]]; then
    resolution="4K"
  elif [[ $width == 1920 ]]; then
    resolution="FHD"
  else
    resolution=$width
  fi

  pix_fmt=$(echo "$metadata" | jq -r '.pix_fmt')
  color_space=$(echo "$metadata" | jq -r '.color_space')
  color_transfer=$(echo "$metadata" | jq -r '.color_transfer')
  color_primaries=$(echo "$metadata" | jq -r '.color_primaries')
  profile=$(echo "$metadata" | jq -r '.profile')
  avg_frame_rate=$(echo "$metadata" | jq -r '.avg_frame_rate')
  if [[ "$avg_frame_rate" == "48000/1001" ]]; then
    fps="48FPS"
  elif [[ "$avg_frame_rate" == "50/1" ]]; then
    fps="50FPS"
  else
    fps="30FPS"
  fi

  XPOS=0
  YPOS=0
  kdialog --msgbox "Resolution: $resolution\nPIX_FMT: $pix_fmt\nColor Space: $color_space\nVideo Profile: $profile\nColor Transfer: $color_transfer\nColor Primaries: $color_primaries\nFPS: $fps" --title "metadata list" --geometry 400x300+$XPOS+$YPOS &
  metadata_pid=$!
}

function set_start_time() {
    requested_start_time=${1:-00:00:00}
    if [[ -z "$START_TIME" ]]; then
        START_TIME=$(kdialog --title "video clipping time" --inputbox "START TIME:" "$requested_start_time")
        if [[ $? = 1 ]]; then
            return 1
        fi
    fi
}

function set_end_time() {
  requested_end_time=${1:-$runtime}
  if [[ -z "$END_TIME" ]]; then
      END_TIME=$(kdialog --title "video clipping time" --inputbox "END TIME:" "$requested_end_time")
      if [[ $? = 1 ]]; then
          return 1
      fi
  fi
}

function manage_star_rating() {
  local FILEPATH="$1"
  current_star_rating=$(getfattr -n user.baloo.rating -e text --only-values "$FILEPATH")
  if [[ -z $current_star_rating ]]; then
    current_star_rating=0
  else
    current_star_rating=$((current_star_rating / 2))
  fi

  radiolist_options=""
  for i in {0..5}; do
    if [[ $i -eq $current_star_rating ]]; then
      on_off="on"
    else
      on_off="off"
    fi
    radiolist_options+="$i ${i}★ $on_off "
  done

  star_rating=$(kdialog --title "Select a Rating" --radiolist "Choose a rating from 1 to 5" $radiolist_options)

  if [ -z "$star_rating" ]; then
    kdialog --error "No rating selected"
    exit 1
  fi

  new_star_rating="$((star_rating * 2))"
  setfattr -n user.baloo.rating -v "$new_star_rating" "$FILEPATH"

  stars=$(printf '%0.s★' $(seq 1 "$star_rating"))
}

function screen_dimensions() {
  local SCREEN_WIDTH
  SCREEN_WIDTH=$(xrandr | grep '*' | awk '{print $1}' | cut -d 'x' -f1 | head -n 1)

  local GEOMETRY_WIDTH="50%"
  local GEOMETRY_POSITION_X=$((SCREEN_WIDTH / 2))
  local GEOMETRY_POSITION_Y=0


  local GEOMETRY_STRING="${GEOMETRY_WIDTH}+${GEOMETRY_POSITION_X}+${GEOMETRY_POSITION_Y}"
  echo "$GEOMETRY_STRING"
}

function play_video() {
  local FILEPATH="$1"
  local GEOMETRY_STRING
  GEOMETRY_STRING=$(screen_dimensions)
  local lut=
  if [[ "$color_space" == "bt709" && "$pix_fmt" == "yuv420p10le" ]]; then
    lut="--lut=/home/thomas/Downloads/DJI-Mavic-3-D-Log-to-Rec-709-V1.cube"
  else
    lut=
  fi
  sleep 0.2
  mpv --no-config --input-ipc-server=/tmp/mpv1 --keep-open --pause --vo=gpu-next --hwdec=auto-copy --video-unscaled=yes --script-opts=osc-timems=yes --script-opts=osc-visibility=always $lut "$FILEPATH" >/dev/null 2>&1 &
  sleep 0.3

  mpv --no-config --input-ipc-server=/tmp/mpv2 --keep-open --pause --vo=gpu-next --hwdec=auto-copy --script-opts=osc-timems=yes --script-opts=osc-visibility=always --geometry="$GEOMETRY_STRING" $lut "$FILEPATH" >/dev/null 2>&1 &
  sleep 0.2

  (echo '{ "command": ["set_property", "pause", false] }' | tee >(socat - /tmp/mpv1) >(socat - /tmp/mpv2) >/dev/null 2>&1) >/dev/null 2>&1

}

function check_file_exists() {
  dir_final="$1"
  trimmed_filename="$2"
    if [[ -f "$dir_final/$trimmed_filename" ]]; then
      i=1
        increment_filename="${file_base_name}-trim"
        while [[ -f "${dir_final}/$increment_filename-$i.${file_extension}" ]]; do
          i=$((i+1))
        done
      output_filename="$increment_filename-$i.${file_extension}"

    else
      output_filename="$trimmed_filename"
    fi
    echo "$output_filename"
}

function edit_filenames() {
  local FILEPATH="$1"
  filename=$(basename "$FILEPATH")
  file_base_name=${filename%.*}
  file_extension=${filename##*.}
  dir_path=$(dirname "$FILEPATH")
  dir_final="$dir_path/trimmed_videos"
  mkdir -p "$dir_final"
  trimmed_filename="${file_base_name}-trim.${file_extension}"

  output_filename="$(check_file_exists "$dir_final" "$trimmed_filename")"
  export output_path="$dir_final/$output_filename"
}

function copy_attributes() {
  source="$1"
  file_list="$2"
  tags=$(getfattr -n user.xdg.tags --only-values "$source")
  for target in $file_list; do
    setfattr -n user.xdg.tags -v "$tags" "$target"
    setfattr -n user.baloo.rating -v "$new_star_rating" "$target"
  done

}

function time_dialog() {
  while true; do
    kdialog  --yesnocancel "grab time" --geometry 400x300+0+300 --title "set time" --yes-label "start" --no-label "end"
    answer=$(echo "$?")
    if [ "$answer" = 0 ]; then # If the user clicks yes
      playtime=$(echo '{ "command": ["get_property", "playback-time"] }' | socat - /tmp/mpv2 | jq .data)
      hhmmss=$(date -u -d @${playtime} +"%T")
      set_start_time ${hhmmss}
    elif [ "$answer" = 1 ]; then
      playtime=$(echo '{ "command": ["get_property", "playback-time"] }' | socat - /tmp/mpv2 | jq .data)
      hhmmss=$(date -u -d @${playtime} +"%T")
      set_end_time ${hhmmss}
      break
    else
      return 1
    fi
  done
}

function Get_Filepath() {
  if [[ -z $1 ]]; then
      printf '%s\n' "$usage_string"
      exit 1
  fi
  if [[ -f $1 ]]; then
    echo "$1"
  else
    echo "$PWD"
  fi
}

function setup() {
  local FILEPATH="$1"
  runtime=$(ffmpeg -hide_banner -i "$FILEPATH" 2>&1 | grep "Duration" | awk '{print $2}' | tr -d ,)
  metadata=$(ffprobe -v quiet -print_format json -show_streams "$FILEPATH" | jq '.streams[0]')
  extract_metadata "$FILEPATH"
  play_video "$FILEPATH"

}

function ffmpeg_trim_video() {
  local FILEPATH="$1"
  local START_TIME="$2"
  local END_TIME="$3"
  (ffmpeg -hide_banner -v warning -ss "$START_TIME" -to "$END_TIME" -i "$FILEPATH" -c copy -y "$output_path" &) > `tty`
}

function run_main(){
  local file_tags
  local FILEPATH="$1"
  local file_list=()

  unset "$NEW_START_TIME"
  while [[ "$END_TIME" < "$runtime" ]]; do
    time_dialog
    local input_time_result=$?
    if [[ $input_time_result = 1 ]]; then
      unset END_TIME
      unset NEW_START_TIME
      kdialog --title "video clip delete origin" --warningyesno "DELETE ORIGINAL?"
      delete_value=$?
      if [[ $delete_value = 0 ]]; then
        kioclient5 move "$@" trash:/
      fi
      pkill -P $$
      return
    fi
    edit_filenames "$FILEPATH"
    file_list+=("$output_path")

    (echo '{ "command": ["set_property", "pause", true] }' | tee >(socat - /tmp/mpv1) >(socat - /tmp/mpv2)) >/dev/null 2>&1

    ffmpeg_trim_video "$FILEPATH" "$START_TIME" "$END_TIME"
    sleep 0.5
#    mpv --input-ipc-server=/tmp/mpv4 --hwdec=auto-copy --script-opts=osc-timems=yes --script-opts=osc-visibility=always --speed=3 --osd-level=3 "$output_tmp_path" > /dev/null 2>&1
#    kdialog --msgbox $output_tmp_path
    exiftool -quiet -ee -overwrite_original -tagsfromfile "$FILEPATH" "$output_path"
    sleep 0.3
    #cp "$output_tmp_path" "$dir_final/$output_filename"
    #sync -d "$dir_final"
    #rm "$output_tmp_path"
    mpv --input-ipc-server=/tmp/mpv4 --hwdec=auto-copy --script-opts=osc-timems=yes --script-opts=osc-visibility=always --speed=3 --osd-level=3 "$dir_final/$output_filename" > /dev/null 2>&1
    sleep 0.1
    unset START_TIME
    NEW_START_TIME=$END_TIME

    if [[ "$END_TIME" < "$runtime" ]]; then
      unset END_TIME
      kdialog --title "Source video has more time" --yesno "Continue clipping from this video?"
          continue_value=$?
          if [[ $continue_value = 0 ]]; then
            (echo '{ "command": ["set_property", "pause", false] }' | tee >(socat - /tmp/mpv1) >(socat - /tmp/mpv2) >/dev/null 2>&1) >/dev/null 2>&1

            continue
          else
            break
          fi
    else
        break
    fi
  done
    sleep 0.1
    manage_star_rating "$1"
    sleep 0.1
    unset END_TIME
    unset NEW_START_TIME
    file_tags="$(select_tags "$FILEPATH")"
    (echo '{ "command": ["quit"] }' | tee >(socat - /tmp/mpv1) >(socat - /tmp/mpv2) >/dev/null 2>&1) >/dev/null 2>&1
    copy_attributes "$FILEPATH" "${file_list[@]}"
    sleep 0.1
    kdialog --title "video clip delete origin" --warningyesno "DELETE ORIGINAL?"
    delete_value=$?
    if [[ $delete_value = 0 ]]; then
      kioclient5 move "$@" trash:/
    fi
    sleep 0.1
    echo "$file_tags"
}

function clean_up() {
  (echo '{ "command": ["quit"] }' | tee >(socat - /tmp/mpv1) >(socat - /tmp/mpv2) >/dev/null 2>&1) >/dev/null 2>&1
  pkill -P $$
  kill $$
  exit 1
}

if [[ -z $1 ]]; then
  directory=/home/thomas/Videos/to_be_trimmed
else
  directory=$1
fi

initialise_file_tags

for file in "$directory"/*
do
  mime=$(file --mime-type -b "$file")
  if [[ $mime == video/* ]]; then
    FILEPATH=$(Get_Filepath "$file")
    setup "$FILEPATH"
    previous_tags="$(run_main "$FILEPATH")"
    kill -9 "$metadata_pid"
  fi
done

exit 0

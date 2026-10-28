cd /gscratch/scrubbed/fanglab/xiaoqian/IFOCUS/sourcedata/dicom

find . -name "*.dicom.zip" | while read z; do
  d=$(dirname "$z")
  echo "Unzipping $z"
  unzip -n "$z" -d "$d"
done

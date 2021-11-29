#!/bin/bash
while getopts i:n: flag

 do 
    case "${flag}" in
     i)
      i=${OPTARG}
       ;;
     n) 
      n=${OPTARG}
       ;; 
     *) echo "Invalid option: -$flag" 
       ;;
    esac
done
for j in $(seq 0 $n );do
     ping -c1 -q 8.8.8.8
    sleep $i
done    

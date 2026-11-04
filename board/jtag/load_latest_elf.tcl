set script_dir [file dirname [file normalize [info script]]]
set elf_file [file normalize [file join $script_dir .. .. build artifacts stage37_model_candidate.elf]]

if {![file exists $elf_file]} {
    error "Stage37 ELF not found: $elf_file"
}

connect -url tcp:127.0.0.1:3121
after 500

targets -set -filter {name =~ "ARM Cortex-A9 MPCore #0"}
catch {stop}
rst -processor
after 300

dow $elf_file
con
after 3000

puts {LATEST_ELF_DOWNLOAD_STATUS=Running}
puts "LATEST_ELF=$elf_file"
disconnect
exit

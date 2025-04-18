## Prerequisits
1. Check for requirements.txt and install missing utils.
2. Check for cowsay site source dir.
3. This script runs only on macOS because relies on some OS specific tools (pbcopy, qlmanage etc.)
4. Create secrect.sh file with two vars: API_KEY and TOKEN. Those are trello credentials to run trello.sh script.
5. Visit vars.sh and adjust path to your locations:
  * COWSAY_DIR: where you want to store all the working files, mp3's, csv's, txt's etc.
  * COVER: cowsay podcast cover image for adding meta to resulting file.
  * AZURE_DIR: azure file storage URL used for upload.
  * COWSAY_SOURCE: cowsay site sources location.
  * GITHUB_CERT_PATH: for updating repo with new episode.
  * AZURE_CERT_PATH: for updating cowsay site on Azure hosting.
  * LOCAL_ADDRESS: likely stays the same, for testing, local server.
  * PUBLIC_ADDRESS: also less probable to change, but who knows, cowsay show public site URL.

## How to use the scripts
1. Before running the show use trello.sh to download the topics in a csv file.
```bash
./trello.sh '11 April' 666
```
2. While running the show load this csv file into Records app and register the timestamps.
3. Generate the Records.csv file after the show. Name it Records-<show_number>.csv
4. use episode.sh script to do the rest (prepare audio, description, publish). Follow the messages in the console and check for intermediate results.
```bash
./episode.sh -e 666 -t "Live 666: April's dry run" -s "/Users/user/Downloads/666.mp3" -u
```

List of available options for this command:
  * -e <number>, episode number
  * -y <url>, youtube episode url in case it's used as a source
  * -t <text>, episode title
  * -s <path>, local mp3 source file to use
  * -u, upload to azure

### Don't forget to have fun ;)
#!/bin/bash

echo "[c1p document job] invoked copado job"

CSV_FILE_NAME=${FILE_NAME:-opportunities.csv}

notify_status "Retrieving_data" "20" 
echo "[c1p document job] Retrieving data"
# get all the closed-won opportunities
curl -sS "${COPADO_SF_SERVICE_ENDPOINT}query?q=SELECT+Id,+Name,+StageName,+AccountId,+Account.Name,+(select+Id,+Pricebookentry.product2.name+from+OpportunityLineItems)from+opportunity+WHERE+StageName+=+'Closed+Won'" \
-H 'Authorization: Bearer '"$COPADO_SF_AUTH_HEADER"'' \
| jq -c -r '["OpportunityId","OpportunityName","OpportunityStageName","AccountId","AccountName","ProductId","ProductName"], (.records[] | [.Id, .Name, .StageName, .AccountId, .Account.Name, .OpportunityLineItems.records[0].Id, .OpportunityLineItems.records[0].PricebookEntry.Product2.Name ]) | @csv' > $CSV_FILE_NAME

notify_status "Retrieving_attachments" "40"
# download all attachment files for the opportunities
echo "[c1p document job] Downloading files"
mkdir attachments
curl -sS "${COPADO_SF_SERVICE_ENDPOINT}query?q=SELECT+Id,+Name,+StageName,+AccountId,+Account.Name,+(select+Id,+Pricebookentry.product2.name+from+OpportunityLineItems)from+opportunity+WHERE+StageName+=+'Closed+Won'" -H 'Authorization: Bearer '"$COPADO_SF_AUTH_HEADER"'' | jq -c -r '.records[] | [.Id]' | sed "s/\"/'/g" | sed "s/[^a-zA-Z0-9']/ /g" | tr '\n' ',' | tr -d " " | sed 's/.$//' > ./.opportunities.id
curl -sS "${COPADO_SF_SERVICE_ENDPOINT}query?q=Select+id,+ContentDocumentId,+ContentDocument.LatestPublishedVersionId+from+ContentDocumentLink+where+LinkedEntityId+IN+($(cat ./.opportunities.id))" -H 'Authorization: Bearer '"$COPADO_SF_AUTH_HEADER"'' | jq -c -r '.records[] | .ContentDocument.LatestPublishedVersionId' > ./.content.doc.id
while read docId; do
  echo "[c1p document job] downloading $docId"
  mkdir attachments/$docId
  curl -sS "${COPADO_SF_SERVICE_ENDPOINT}sobjects/ContentVersion/$docId" -H 'Authorization: Bearer '"$COPADO_SF_AUTH_HEADER"'' | jq -r -c .PathOnClient > ./.curr.file.name
  curl -sS "${COPADO_SF_SERVICE_ENDPOINT}sobjects/ContentVersion/$docId/VersionData"  -H 'Authorization: Bearer '"$COPADO_SF_AUTH_HEADER"'' -o "./attachments/$docId/$(cat ./.curr.file.name)"
done <./.content.doc.id

notify_status "Compressing_data" "50"
echo "[c1p document job] Compressing data"
# zip all the attachments and the opportinities csv
zip -qr --password copado opportunities.zip $CSV_FILE_NAME attachments/* ./.opportunities.id ./.content.doc.id

notify_status "Uploading_data_to_FTP" "60" 
echo "[c1p document job] Uploading FTP data"
# upload to FTP server
curl -sS -T opportunities.zip -u "$FTP_USER":"$FTP_PWD" "$FTP_URL3/opportunities-$(date +%s).zip"

#
# before you will need:
# 1.- Enable oauth access to your drive account
# 2.- request a CODE https://accounts.google.com/o/oauth2/auth?client_id=XXX&redirect_uri=urn:ietf:wg:oauth:2.0:oob&response_type=code&scope=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fdrive
# 3.- login to get the access_token curl -XPOST --data "code=CODE&client_id=XXX&client_secret=YYY&redirect_uri=urn:ietf:wg:oauth:2.0:oob&grant_type=authorization_code" "https://accounts.google.com/o/oauth2/token"
notify_status "Uploading_data_to_Google_Drive" "80" 
echo "[c1p document job] Uploading GDrive data"
# get access token
echo "[c1p document job] Getting GDrive access token"
curl -sS -XPOST --data "grant_type=refresh_token&client_id=$GDRIVE_CLIENT_ID&client_secret=$GDRIVE_SECRET&refresh_token=$GDRIVE_TOKEN" "https://accounts.google.com/o/oauth2/token" | jq -cr '.access_token' > ./.drive_token
# put file metadata
echo "[c1p document job] Uploading GDrive file metadata"
curl -sD - -XPOST "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&part=snippet" -H "Content-Type: application/json" -H "Authorization: Bearer $(cat ./.drive_token)" -d "{\"name\":\"opportunities-$(date +%s).zip\"}" | tr -d '\r' | sed -En 's/^X-GUploader-UploadID: (.*)/\1/p' > ./.fileid 
# put fil
echo "[c1p document job] Uploading GDrive file"
curl -sL -XPOST "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&part=snippet&upload_id=$(cat ./.fileid)" -H "Authorization: Bearer $(cat ./.drive_token)" -H "Content-type: application/zip" --data-binary @opportunities.zip > /dev/null

notify_status "Copado_rulez" "100" 
echo "[c1p document job] Finished"

# LLM client handler for natural language shell commands

# Helper function to validate environment
nlsh-validate-environment() {
    local provider=${LLM_PROVIDER:-"openai"}
    
    case "$provider" in
        "openai")
            if [[ -z $OPENAI_API_KEY ]]; then
                echo "Error: OPENAI_API_KEY environment variable is not set"
                return 1
            fi
            ;;
        "gemini")
            if [[ -z $GOOGLE_API_KEY ]]; then
                echo "Error: GOOGLE_API_KEY environment variable is not set"
                return 1
            fi
            ;;
        *)
            echo "Error: Unsupported LLM provider: $provider"
            return 1
            ;;
    esac
    return 0
}


nlsh-parse-response() {
    local response="$1"
    local provider=${LLM_PROVIDER:-"openai"}
    
    local content
    case "$provider" in
        "openai")
            if ! content=$(echo "$response" | jq -r '
                if .choices[0].message.content != null then
                    .choices[0].message.content
                else
                    "error: unknown response format"
                end' 2>/dev/null); then
                echo "Error: Failed to parse OpenAI response: $response"
                return 1
            fi
            ;;
        "gemini")
            # Gemini adds unescaped newlines for some reason. 
            if ! content=$(echo "$response" | jq -Rs 'gsub("\n";"") | fromjson|
                if .candidates[0].content.parts[0].text != null then
                    .candidates[0].content.parts[0].text
                elif .error != null then
                    "error: " + .error.message
                else
                    "error: unknown response format"
                end' -r 2>/dev/null); then
                echo "Error: Failed to parse Gemini response: $response"
                export $response
                zsh -i
                return 1
            fi
            ;;
    esac
    
    # Check for error in content
    if [[ "$content" == "error:"* ]]; then
        echo "Error: $content"
        return 1
    fi
    
    # Trim any trailing whitespace
    content="${content%"${content##*[![:space:]]}"}"
    
    printf '%b' "$content"
}
nlsh-prepare-payload() {
    local input=$1
    local system_context=$2
    local provider=${LLM_PROVIDER:-"openai"}
    
    case "$provider" in
        "openai")
            local model=${OPENAI_MODEL:-"gpt-3.5-turbo"}
            cat <<EOF
{
    "model": "$model",
    "messages": [
        {"role": "system", "content": "You are a shell command generator. Only output the exact command to execute in plain text. Do not include any other text. Do not use Markdown. System context: $system_context"},
        {"role": "user", "content": "$input"}
    ],
    "temperature": 0
}
EOF
            ;;
        "gemini")
            local model=${GEMINI_MODEL:-"gemini-2.0-flash-exp"}
            cat <<EOF
{
    "contents": [
        {
            "role": "user",
            "parts": [
                {
                    "text": "You are a shell command generator. Only output the exact command to execute in plain text. Do not include any other text. Do not use Markdown. Do not add trailing newlines to your response. System context: $system_context\n\nUser request: $input"
                }
            ]
        }
    ],
    "generationConfig": {
        "temperature": 1,
        "topK": 40,
        "topP": 0.95,
        "maxOutputTokens": 8192,
        "responseMimeType": "text/plain"
    }
}
EOF
            ;;
    esac
}

nlsh-make-api-request() {
    local payload=$1
    local provider=${LLM_PROVIDER:-"openai"}
    local curl_cmd=(curl -s -S)
    
    # Add proxy if configured
    [[ -n $OPENAI_PROXY ]] && curl_cmd+=(--proxy "$OPENAI_PROXY")
    
    # Determine API endpoint and headers
    local url
    local headers=(-H "Content-Type: application/json")
    
    case "$provider" in
        "openai")
            url="${OPENAI_URL_BASE:-https://api.openai.com}/v1/chat/completions"
            headers+=(-H "Authorization: Bearer $OPENAI_API_KEY")
            ;;
        "gemini")
            url="${GOOGLE_URL_BASE:-https://generativelanguage.googleapis.com}/v1beta/models/${GEMINI_MODEL:-gemini-2.0-flash-exp}:generateContent?key=$GOOGLE_API_KEY"
            ;;
    esac
    
    # Make API request with error handling
    local response
    if ! response=$("${curl_cmd[@]}" "${headers[@]}" \
         --max-time 30 \
         -d "$payload" \
         "$url" 2>&1); then
        echo "Error: Failed to connect to API - $response"
        return 1
    fi
    
    echo "$response"
}

nlsh-check-api-error() {
    local response=$1
    local provider=${LLM_PROVIDER:-"openai"}
    
    case "$provider" in
        "openai")
            if echo "$response" | jq -e '.error' >/dev/null 2>&1; then
                local error_msg=$(echo "$response" | jq -r '.error.message')
                echo "Error: OpenAI API request failed - $error_msg"
                return 1
            fi
            ;;
        "gemini")
            if echo "$response" | jq -e '.error' >/dev/null 2>&1; then
                local error_msg=$(echo "$response" | jq -r '.error.message')
                echo "Error: Gemini API request failed - $error_msg"
                return 1
            fi
            ;;
    esac
    return 0
}

nlsh-llm-get-command() {
    local input=$1
    local system_context=$2
    
    # Validate environment
    nlsh-validate-environment || return 1
    
    # Prepare request payload
    local payload
    payload=$(nlsh-prepare-payload "$input" "$system_context")
    
    # Make API request
    local response
    response=$(nlsh-make-api-request "$payload") || return 1
    
    # Check for API errors
    nlsh-check-api-error "$response" || return 1
    
    # Parse and return response
    nlsh-parse-response "$response"
}

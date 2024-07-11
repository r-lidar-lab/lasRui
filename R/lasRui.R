library(shiny)
library(shinyjs)

# Convert a list to an HTML table
list_to_html_table <- function(lst)
{
  html <- "<table class='table table-striped'><thead><tr><th>Stage</th><th>File</th></tr></thead><tbody>"
  for (key in names(lst)) {
    value <- lst[[key]]
    html <- paste0(html, "<tr><td>", key, "</td><td>", value, "</td></tr>")
  }
  html <- paste0(html, "</tbody></table>")
  return(HTML(html))
}

#' User Interface for visual programming of lasR pipeline
#'
#' Drag and drop and connect stages to build a pipeline using a web API
#'
#' @export
#' @import shiny
lasRui = function()
{
  ui <- fluidPage(
    shinyjs::useShinyjs(),  # Include shinyjs
    tags$head(
      tags$style(HTML("
      .overlay {
        position: absolute;
        top: 15px;
        left: 300px;
        z-index: 10;
        display: flex;
        gap: 10px;
        height:34px;
      }
      .iframe-container {
        position: relative;
        width: 100%;
        height: 600px;
      }
      .btn-run {
        color: white;
        font-weight: bold;
        border: 1px solid #0e5ba3;
        background: #4ea9ff;
        padding: 5px 10px;
        border-radius: 4px;
        cursor: pointer;
        z-index: 5;
      }
      .btn-clear {
        color: white;
        font-weight: bold;
        border: 1px solid #96015b;
        background: #e3195a;
        padding: 5px 10px;
        border-radius: 4px;
        cursor: pointer;
        z-index: 5;
      }
      .btn-save {
        color: white;
        font-weight: bold;
        border: 1px solid #0e5ba3;
        background: #4ea9af;
        padding: 5px 10px;
        border-radius: 4px;
        cursor: pointer;
        z-index: 5;
      }
      iframe {
        width: 100%;
        height: 100%;
        border: none;
      }
    "))
    ),
    div(class = "iframe-container",
        div(class = "overlay",
            actionButton("run_btn", "Run", class = "btn-run"),
            actionButton("stop_btn", "Stop", class = "btn-clear"),
            actionButton("save_btn", "Save as", class = "btn-save"),
            actionButton("clear_btn", "Clear", class = "btn-clear"),
            fileInput("file_upload", NULL, buttonLabel = "Load pipeline", accept = c(".json"))
        ),
        htmlOutput("map")
    )
  )

  addResourcePath("drawflow", system.file("extdata", "ui", package="lasR"))

  server <- function(input, output, session)
  {
    shinyjs::hide("stop_btn")

    # Render the iframe
    output$map <- renderUI({
      tags$iframe(
        seamless = "seamless",
        src = "drawflow/index.html",
        id = "iframe_id",
        style = 'width:100%;height:100vh;'
      )
    })

    # Run sends a message to the HTML API to get the JSON pipeline
    # The API send back a message with the pipeline. The message is
    # receive by observe()
    observeEvent(input$run_btn,
    {
      shinyjs::hide("run_btn")
      shinyjs::show("stop_btn")

      shinyjs::runjs("
      console.log('Sending message to iframe...');
      var iframe = document.getElementById('iframe_id');
      iframe.contentWindow.postMessage('APITriggerRun', '*');")

      showNotification("Run pipeline")
    })

    observeEvent(input$stop_btn,
    {
      shinyjs::show("run_btn")
      shinyjs::hide("stop_btn")

      showNotification("Stop not supported yet")
    })

    observeEvent(input$clear_btn,
    {
      shinyjs::runjs("
      console.log('Sending message to iframe...');
      var iframe = document.getElementById('iframe_id');
      iframe.contentWindow.postMessage('APITriggerClear', '*');")

      showNotification("Clear pipeline")
    })

    observeEvent(input$save_btn,
    {
      shinyjs::runjs("
      console.log('Sending message to iframe...');
      var iframe = document.getElementById('iframe_id');
      iframe.contentWindow.postMessage('APITriggerExport', '*');")

      showNotification("Save pipeline")
    })

    # Listen for messages from the HTML API. When run is triggered the API
    # return the JSON pipeline in a message. Update input to trigger run
    observe({
      shinyjs::runjs("
      window.addEventListener('message', function(event) {
        if (event.data.type === 'ExportData') {
          Shiny.setInputValue('iframe_data', event.data.payload);
        }
      });")
    })

    # iframe_data has been modified after the HTML API sent a message with the
    # pipeline. Run the pipeline
    observeEvent(input$iframe_data,
    {
      pipeline = jsonlite::prettify(input$iframe_data)

      async_com0 = paste0(tempdir(), "/lasr_com0.tmp")
      writeLines("0", async_com0)

      pipeline = lasR:::interpolate_R_expression(pipeline)

      cat("Data received from iframe:\n")
      temp_file <- tempfile(fileext = ".json")
      writeLines(pipeline, temp_file)
      cat("Pipeline saved to temp file: ", temp_file, "\n")
      cat("Running...\n")

      future::plan(future::multisession)
      promise <- future::future({ .Call(lasR:::`C_process`, temp_file, async_com0)}, seed = TRUE)

      withProgress(message = 'Calculation in progress',
      {
        while (!future::resolved(promise))
        {
          Sys.sleep(1)
          pgrs = scan(async_com0, what = "character",sep="\n")
          pgrs = as.numeric(pgrs)
          setProgress(pgrs)
        }
      })

      unlink(async_com0)

      ans = future::value(promise)
      if (inherits(ans, "error"))
      {
        output$modalContent <- renderText({ans$message})

        showModal(modalDialog(
          title = "Error",
          uiOutput("modalContent"),
          easyClose = TRUE,
          footer = NULL))

        return(NULL)
      }

      ans = Filter(Negate(is.null), ans)

      shinyjs::show("run_btn")
      shinyjs::hide("stop_btn")

      output$modalContent <- renderUI({
        list_to_html_table(ans)
      })

      showModal(modalDialog(
        title = "Output",
        uiOutput("modalContent"),
        easyClose = TRUE,
        footer = NULL
      ))

      cat("Computation done.\n")
    })

    # Observe when a file is uploaded
    observeEvent(input$file_upload,{
      req(input$file_upload)  # Ensure a file is uploaded

      # Read the uploaded file
      file <- input$file_upload$datapath
      pipeline = readLines(file)
      pipeline = jsonlite::minify(pipeline)
      pipeline = gsub('\\\\n', '\\\\\\\\n', pipeline)
      pipeline = gsub('\\\\"', '\\\\\\\\"', pipeline)

      cat("Sent", file, "\n")

      js_code <- sprintf("
      console.log('Sending file to iframe...');
      var message = {
        type: 'APITriggerUpload',
        payload: '%s'
      };
      var iframe = document.getElementById('iframe_id');
      iframe.contentWindow.postMessage(message, '*');
    ", pipeline)

      shinyjs::runjs(js_code)
    })
  }

  shinyApp(ui, server)
}
